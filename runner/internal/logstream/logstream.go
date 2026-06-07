// Package logstream batches a Job's Step output into sequenced log:chunk
// messages and ships them at-least-once over the Runner's Channel
// (docs/prd/runner-protocol.md, ADR 0004).
//
// Behaviour the protocol requires:
//
//   - Batching: a chunk flushes when it reaches max_bytes OR when max_interval
//     elapses since the first unflushed byte, whichever trips first (both
//     delivered in job:assign, never baked into the image).
//   - Sequencing: every chunk carries a per-Job monotonic seq (1..N), assigned
//     here, that never resets across Step boundaries; plus the step_index of the
//     Step that produced it (metadata only — content stays pure).
//   - At-least-once, acked: a chunk is "done" only once SendChunk returns (the
//     control plane acks after handing the chunk to the LogStore). Close blocks
//     until every chunk is acked, so the caller sends job:finished only after
//     nothing is left in flight ("nothing is lost when the Runner is destroyed").
//   - Bounded buffer, block on full: at most MaxUnacked chunks may be in flight;
//     a further flush blocks the writing Step (pipe backpressure) rather than
//     dropping output. The connection returning (acks flowing) releases it.
package logstream

import (
	"context"
	"io"
	"sync"
	"time"
)

// Chunk is one batched log:chunk (the wire payload is {seq, step_index, content}).
type Chunk struct {
	Seq       int
	StepIndex int
	Content   []byte
}

// Sender ships one chunk and returns only after it is acked (the control plane
// acks after the LogStore handoff). A non-nil error means the chunk was not
// durably accepted; the Streamer surfaces it from Close.
type Sender interface {
	SendChunk(ctx context.Context, c Chunk) error
}

// Config carries the batching limits (from job:assign) and the unacked-buffer
// cap (the backpressure bound).
type Config struct {
	MaxBytes    int
	MaxInterval time.Duration
	// MaxUnacked caps chunks in flight (unacked). Defaults to a small constant
	// when zero. The bound, plus the grace period, bounds the stall window.
	MaxUnacked int
}

const defaultMaxUnacked = 8

// Streamer batches Step output into chunks and ships them through a Sender.
// One Streamer serves one Job; create per-Step writers with StepWriter.
type Streamer struct {
	sender Sender
	cfg    Config

	// queue carries flushed chunks to the sender goroutine in order.
	queue chan Chunk
	// inflight is a semaphore of MaxUnacked permits: a permit is acquired before
	// a chunk is enqueued and released only after its ack. When it is exhausted,
	// a flushing writer blocks (pipe backpressure) until an ack frees a permit —
	// so the bound counts chunks awaiting ack, including the one being sent.
	inflight chan struct{}
	// cancel cancels cctx, the context the sender goroutine sends under and that
	// enqueue's blocking sends select on. Close fires it when its own ctx is
	// cancelled, so a permanently-stalled control plane can never leave an
	// unkillable goroutine (or a wedged enqueue) behind after Close returns.
	cctx   context.Context
	cancel context.CancelFunc
	// sendErr holds the first send failure; surfaced from Close.
	sendErr error
	errOnce sync.Once
	done    chan struct{}

	mu      sync.Mutex
	nextSeq int
	writers []*stepWriter
}

// New returns a Streamer shipping chunks through sender under cfg, and starts
// its single sender goroutine.
func New(sender Sender, cfg Config) *Streamer {
	if cfg.MaxUnacked <= 0 {
		cfg.MaxUnacked = defaultMaxUnacked
	}
	if cfg.MaxBytes <= 0 {
		cfg.MaxBytes = 64 * 1024
	}
	cctx, cancel := context.WithCancel(context.Background())
	s := &Streamer{
		sender:   sender,
		cfg:      cfg,
		queue:    make(chan Chunk, cfg.MaxUnacked),
		inflight: make(chan struct{}, cfg.MaxUnacked),
		cctx:     cctx,
		cancel:   cancel,
		done:     make(chan struct{}),
	}
	go s.run()
	return s
}

// StepWriter returns an io.Writer for the given Step index; writing to it feeds
// the batcher (stdout and stderr of one Step share one writer so the two merge
// in pipe-arrival order, untagged).
func (s *Streamer) StepWriter(stepIndex int) io.Writer {
	w := &stepWriter{s: s, stepIndex: stepIndex}
	s.mu.Lock()
	s.writers = append(s.writers, w)
	s.mu.Unlock()
	return w
}

// Close flushes any buffered bytes, then blocks until every chunk has been
// acked. Returns the first send error, if any. After Close the caller may send
// job:finished (PRD: only after all chunks acked).
//
// On the normal path the ctx is unused and at-least-once semantics hold: every
// buffered byte is flushed and every chunk is acked before Close returns. The
// ctx is the escape hatch for a permanently-stalled control plane: cancelling it
// unblocks the flush loop, any backpressured enqueue, and the sender's in-flight
// SendChunk (via the sender's context), so Close returns ctx.Err() instead of
// hanging — and crucially leaves no unkillable sender goroutine behind.
func (s *Streamer) Close(ctx context.Context) error {
	// If ctx is cancelled at any point, fire the sender's context too: that frees
	// a backpressured enqueue and a stalled in-flight SendChunk so the sender
	// goroutine can exit rather than leak.
	defer s.cancel()

	// Flush each Step writer's tail so no buffered bytes are stranded. Each Flush
	// can block on backpressure (enqueue), so honor ctx between writers — a
	// cancel makes enqueue return and lets us bail out of the flush loop.
	s.mu.Lock()
	writers := make([]*stepWriter, len(s.writers))
	copy(writers, s.writers)
	s.mu.Unlock()
	for _, w := range writers {
		select {
		case <-ctx.Done():
			s.cancel()
			return ctx.Err()
		default:
		}
		w.Flush()
	}

	close(s.queue)
	select {
	case <-s.done:
	case <-ctx.Done():
		// Cancel the sender's context so a stalled SendChunk / blocked enqueue
		// unwinds and the goroutine exits; then return without waiting on it.
		s.cancel()
		return ctx.Err()
	}
	return s.sendErr
}

// run is the single sender goroutine: it pulls flushed chunks in order and
// sends each (blocking until ack). Pulling one frees a queue slot, which is what
// releases a backpressured writer.
//
// Each SendChunk runs under s.cctx, which Close cancels when its own ctx fires.
// So a permanently-stalled control plane no longer pins this goroutine: the
// cancel makes the in-flight SendChunk return, and the cctx.Done() guard makes
// any further iterations bail rather than block on a CP that will never ack.
func (s *Streamer) run() {
	defer close(s.done)
	for {
		// Pull the next chunk, but also wake on cctx so a cancelled Close (stalled
		// CP) tears the goroutine down even when the queue was never closed (Close
		// bails out of its flush loop before closing the queue on an early cancel).
		var c Chunk
		select {
		case <-s.cctx.Done():
			s.errOnce.Do(func() { s.sendErr = s.cctx.Err() })
			return
		case got, ok := <-s.queue:
			if !ok {
				return // queue closed and drained: normal-path completion.
			}
			c = got
		}

		if err := s.sender.SendChunk(s.cctx, c); err != nil {
			s.errOnce.Do(func() { s.sendErr = err })
			// Keep draining so writers don't deadlock; the error is surfaced
			// from Close. (The runner treats a send error as fatal anyway.)
		}
		// Ack received (or send cancelled): release the in-flight permit, freeing a
		// backpressured writer (PRD: the connection returning releases the stall).
		<-s.inflight
	}
}

// enqueue assigns the next seq and hands the chunk to the sender goroutine.
// Blocks when the unacked buffer is full (backpressure), but never
// unconditionally: both blocking sends select on s.cctx so a cancelled Close
// (stalled CP) unwinds a backpressured writer instead of pinning it forever. On
// cancel the chunk is dropped — Close is already returning ctx.Err() and the
// at-least-once guarantee only covers the non-cancelled path.
func (s *Streamer) enqueue(stepIndex int, content []byte) {
	s.mu.Lock()
	s.nextSeq++
	seq := s.nextSeq
	s.mu.Unlock()

	// Copy content: the writer reuses its buffer after the flush returns.
	buf := make([]byte, len(content))
	copy(buf, content)
	// Acquire an in-flight permit first: this is the backpressure point — it
	// blocks when MaxUnacked chunks are already awaiting their ack.
	select {
	case s.inflight <- struct{}{}:
	case <-s.cctx.Done():
		return
	}
	select {
	case s.queue <- Chunk{Seq: seq, StepIndex: stepIndex, Content: buf}:
	case <-s.cctx.Done():
		// Release the permit we just took so a draining run() does not block on a
		// chunk that will never arrive.
		<-s.inflight
		return
	}
}

// stepWriter accumulates one Step's output and flushes on the byte cap or the
// interval timer.
type stepWriter struct {
	s         *Streamer
	stepIndex int

	mu    sync.Mutex
	buf   []byte
	timer *time.Timer
}

func (w *stepWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	total := len(p)
	for len(p) > 0 {
		space := w.s.cfg.MaxBytes - len(w.buf)
		take := len(p)
		if take > space {
			take = space
		}
		w.buf = append(w.buf, p[:take]...)
		p = p[take:]

		if len(w.buf) >= w.s.cfg.MaxBytes {
			// Flush a full chunk. enqueue may block on a full buffer
			// (backpressure) — that pauses this Step's output, as intended.
			w.flushLocked()
		} else if w.timer == nil {
			// First unflushed byte: arm the interval timer so a quiet Step still
			// flushes (keeps live tail live).
			w.armTimerLocked()
		}
	}
	return total, nil
}

func (w *stepWriter) armTimerLocked() {
	if w.s.cfg.MaxInterval <= 0 {
		return
	}
	w.timer = time.AfterFunc(w.s.cfg.MaxInterval, func() {
		w.mu.Lock()
		defer w.mu.Unlock()
		if len(w.buf) > 0 {
			w.flushLocked()
		}
	})
}

func (w *stepWriter) flushLocked() {
	if len(w.buf) == 0 {
		return
	}
	if w.timer != nil {
		w.timer.Stop()
		w.timer = nil
	}
	content := w.buf
	w.buf = nil
	// Release the lock around enqueue so a backpressure block here does not also
	// wedge the interval timer's flush attempt (which also takes w.mu).
	w.mu.Unlock()
	w.s.enqueue(w.stepIndex, content)
	w.mu.Lock()
}

// Flush forces any buffered bytes out as a chunk (used between Steps and before
// Close so the tail is not stranded).
func (w *stepWriter) Flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.flushLocked()
}
