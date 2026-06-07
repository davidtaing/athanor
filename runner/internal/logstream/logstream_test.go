package logstream

import (
	"context"
	"sync"
	"testing"
	"time"
)

// fakeSender records the log:chunk sends and lets a test control when each ack
// returns, so the at-least-once / backpressure behaviour can be driven.
type fakeSender struct {
	mu     sync.Mutex
	chunks []Chunk
	// gate, when non-nil, blocks each Send until the test releases it (to
	// exercise the bounded buffer / backpressure path).
	gate chan struct{}
}

func (f *fakeSender) SendChunk(ctx context.Context, c Chunk) error {
	if f.gate != nil {
		select {
		case <-f.gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	f.mu.Lock()
	f.chunks = append(f.chunks, c)
	f.mu.Unlock()
	return nil
}

func (f *fakeSender) recorded() []Chunk {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Chunk, len(f.chunks))
	copy(out, f.chunks)
	return out
}

func (f *fakeSender) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.chunks)
}

func TestFlushesOnMaxBytes(t *testing.T) {
	snd := &fakeSender{}
	// max_interval long so only the byte cap can trip the flush.
	s := New(snd, Config{MaxBytes: 4, MaxInterval: time.Hour})

	w := s.StepWriter(0)
	// Write 10 bytes against a 4-byte cap: expect at least two full chunks.
	if _, err := w.Write([]byte("0123456789")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := s.Close(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}

	chunks := snd.recorded()
	if len(chunks) < 2 {
		t.Fatalf("got %d chunks, want >=2 (byte cap should split the stream)", len(chunks))
	}
	// Content is preserved and reassembles to the original bytes.
	var joined string
	for _, c := range chunks {
		joined += string(c.Content)
	}
	if joined != "0123456789" {
		t.Fatalf("reassembled = %q, want 0123456789", joined)
	}
	// No chunk exceeds the byte cap.
	for _, c := range chunks {
		if len(c.Content) > 4 {
			t.Fatalf("chunk len %d exceeds max_bytes 4", len(c.Content))
		}
	}
}

func TestFlushesOnMaxInterval(t *testing.T) {
	snd := &fakeSender{}
	// Large byte cap; a short interval must flush a small, quiet write.
	s := New(snd, Config{MaxBytes: 1 << 20, MaxInterval: 20 * time.Millisecond})

	w := s.StepWriter(0)
	if _, err := w.Write([]byte("tick")); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Poll until the interval flush lands (before any Close).
	deadline := time.Now().Add(2 * time.Second)
	for snd.count() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("interval flush never happened")
		}
		time.Sleep(2 * time.Millisecond)
	}
	if err := s.Close(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}

	if got := snd.recorded()[0].Content; string(got) != "tick" {
		t.Fatalf("first chunk = %q, want tick", got)
	}
}

func TestAssignsMonotonicSeqAndStepIndex(t *testing.T) {
	snd := &fakeSender{}
	s := New(snd, Config{MaxBytes: 3, MaxInterval: time.Hour})

	w0 := s.StepWriter(0)
	_, _ = w0.Write([]byte("aaabbb")) // two 3-byte chunks, step 0
	w1 := s.StepWriter(1)
	_, _ = w1.Write([]byte("ccc")) // one chunk, step 1

	if err := s.Close(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}

	chunks := snd.recorded()
	if len(chunks) != 3 {
		t.Fatalf("got %d chunks, want 3", len(chunks))
	}
	// seq is a per-Job monotonic 1..N regardless of Step boundary (PRD).
	for i, c := range chunks {
		if c.Seq != i+1 {
			t.Fatalf("chunk %d seq = %d, want %d", i, c.Seq, i+1)
		}
	}
	if chunks[0].StepIndex != 0 || chunks[1].StepIndex != 0 {
		t.Fatalf("step 0 chunks have wrong step_index: %+v", chunks[:2])
	}
	if chunks[2].StepIndex != 1 {
		t.Fatalf("step 1 chunk step_index = %d, want 1", chunks[2].StepIndex)
	}
}

// TestCloseWaitsForAllAcks: Close returns only after every chunk's Send (ack)
// has completed — this is what makes "job:finished only after all chunks acked"
// true (the runner calls Close before sending job:finished).
func TestCloseWaitsForAllAcks(t *testing.T) {
	gate := make(chan struct{})
	snd := &fakeSender{gate: gate}
	s := New(snd, Config{MaxBytes: 2, MaxInterval: time.Hour})

	w := s.StepWriter(0)
	_, _ = w.Write([]byte("aabb")) // two chunks, both gated

	closed := make(chan error, 1)
	go func() { closed <- s.Close(context.Background()) }()

	select {
	case <-closed:
		t.Fatal("Close returned before chunks were acked")
	case <-time.After(50 * time.Millisecond):
		// Good: Close is blocked waiting on the gated acks.
	}

	// Release the acks; Close must now complete with all chunks recorded.
	close(gate)
	if err := <-closed; err != nil {
		t.Fatalf("close: %v", err)
	}
	if snd.count() != 2 {
		t.Fatalf("acked %d chunks, want 2", snd.count())
	}
}

// TestCloseHonorsCanceledCtx: against a permanently-stalled control plane (the
// gate is never released, so no chunk is ever acked), a Close called with a
// cancelled ctx returns that ctx's error promptly instead of hanging — and the
// sender goroutine actually exits rather than leaking, because Close cancels the
// sender's context, which unblocks the in-flight SendChunk.
func TestCloseHonorsCanceledCtx(t *testing.T) {
	gate := make(chan struct{}) // never closed: the CP never acks
	snd := &fakeSender{gate: gate}
	s := New(snd, Config{MaxBytes: 2, MaxInterval: time.Hour})

	w := s.StepWriter(0)
	_, _ = w.Write([]byte("aabb")) // two chunks, both stuck on the dead gate

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled before Close even flushes

	closed := make(chan error, 1)
	go func() { closed <- s.Close(ctx) }()

	select {
	case err := <-closed:
		if err != ctx.Err() {
			t.Fatalf("Close error = %v, want %v", err, ctx.Err())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close hung on a stalled control plane despite a cancelled ctx")
	}

	// The sender goroutine must have exited (done closed): a cancelled Close that
	// leaves an unkillable goroutine is exactly the leak this guards against.
	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
		t.Fatal("sender goroutine did not exit after a cancelled Close")
	}
}

// TestCloseCancelMidFlightUnblocks: with chunks already in flight and Close
// blocked waiting on acks that never come, cancelling Close's ctx mid-wait makes
// it return ctx.Err() and tears the goroutine down — the cancellation reaches a
// SendChunk that was already blocked when Close was called.
func TestCloseCancelMidFlightUnblocks(t *testing.T) {
	gate := make(chan struct{}) // never released
	snd := &fakeSender{gate: gate}
	s := New(snd, Config{MaxBytes: 2, MaxInterval: time.Hour})

	w := s.StepWriter(0)
	_, _ = w.Write([]byte("aabb"))

	ctx, cancel := context.WithCancel(context.Background())
	closed := make(chan error, 1)
	go func() { closed <- s.Close(ctx) }()

	// Let Close get past the flush and block on the un-acked drain.
	select {
	case <-closed:
		t.Fatal("Close returned before its ctx was cancelled")
	case <-time.After(50 * time.Millisecond):
	}

	cancel()
	select {
	case err := <-closed:
		if err != ctx.Err() {
			t.Fatalf("Close error = %v, want %v", err, ctx.Err())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not unblock after its ctx was cancelled")
	}

	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
		t.Fatal("sender goroutine did not exit after a mid-flight cancel")
	}
}

// TestCloseCancelUnblocksBackpressuredTailFlush pins the ctx-watcher in Close:
// the writer holds buffered tail data while MaxUnacked is already exhausted by
// never-acked sends, so Close blocks INSIDE w.Flush()'s enqueue (not between
// writers, and not on the drain). A cancel arriving at that point must still
// unblock Close — before the watcher, s.cancel() only ran via defer, which a
// Close stuck in Flush never reached.
func TestCloseCancelUnblocksBackpressuredTailFlush(t *testing.T) {
	gate := make(chan struct{}) // never released: the CP never acks
	snd := &fakeSender{gate: gate}
	s := New(snd, Config{MaxBytes: 2, MaxInterval: time.Hour, MaxUnacked: 1})

	w := s.StepWriter(0)
	// One full chunk fills MaxUnacked with a gated, never-acked in-flight send.
	// (Writing more would block THIS goroutine in the write-path flush — the
	// backpressure must be left for Close's tail flush to hit, not the test.)
	_, _ = w.Write([]byte("aa"))
	_, _ = w.Write([]byte("c")) // buffered tail (< MaxBytes, no flush yet)

	ctx, cancel := context.WithCancel(context.Background())
	closed := make(chan error, 1)
	go func() { closed <- s.Close(ctx) }()

	// Close should now be blocked inside the tail flush's enqueue.
	select {
	case <-closed:
		t.Fatal("Close returned while the tail flush should be backpressured")
	case <-time.After(50 * time.Millisecond):
	}

	cancel()
	select {
	case err := <-closed:
		if err == nil {
			t.Fatal("Close returned nil, want a cancellation error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not unblock after cancel during a backpressured tail flush")
	}

	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
		t.Fatal("sender goroutine did not exit after cancel during tail flush")
	}
}

// TestCloseRacesConcurrentTimerFlushes hammers Close against a flurry of
// timer-driven flushes: a tiny MaxInterval means a flush callback is very likely
// to be inside enqueue exactly when Close stops the producers and closes the
// queue. Before the producer-barrier redesign this panicked (send on a closed
// channel); the run loop here exercises that shutdown handshake repeatedly so
// `-race` and the panic-on-closed-send both have many chances to trip.
func TestCloseRacesConcurrentTimerFlushes(t *testing.T) {
	for iter := 0; iter < 50; iter++ {
		snd := &fakeSender{}
		// Sub-millisecond interval + 1-byte cap so every write arms a timer that
		// fires almost immediately, maximising the chance a callback is mid-enqueue
		// when Close runs.
		s := New(snd, Config{
			MaxBytes:    1,
			MaxInterval: 100 * time.Microsecond,
			MaxUnacked:  4,
		})

		// Several writers all driving output concurrently with Close.
		var writers sync.WaitGroup
		stop := make(chan struct{})
		for i := 0; i < 4; i++ {
			w := s.StepWriter(i)
			writers.Add(1)
			go func() {
				defer writers.Done()
				for {
					select {
					case <-stop:
						return
					default:
						// Ignore the error: once Close has fired, writes may race the
						// shutdown — the contract under test is "no panic", not delivery.
						_, _ = w.Write([]byte("x"))
					}
				}
			}()
		}

		// Let the writers get going and timers start firing, then Close into the storm.
		time.Sleep(time.Millisecond)
		if err := s.Close(context.Background()); err != nil {
			t.Fatalf("iter %d: close: %v", iter, err)
		}
		close(stop)
		writers.Wait()
	}
}

// TestBoundedBufferBlocksWriter: once the unacked buffer is full, a further
// Write blocks (pipe backpressure) rather than dropping output — nothing is
// ever silently dropped (PRD).
func TestBoundedBufferBlocksWriter(t *testing.T) {
	gate := make(chan struct{})
	snd := &fakeSender{gate: gate}
	// Buffer of 1 unacked chunk; 1-byte cap so each write byte is its own chunk.
	s := New(snd, Config{MaxBytes: 1, MaxInterval: time.Hour, MaxUnacked: 1})

	w := s.StepWriter(0)

	// First byte → first chunk, taken by the sender (gated, so it stays unacked).
	if _, err := w.Write([]byte("a")); err != nil {
		t.Fatalf("write a: %v", err)
	}

	// Second byte → second chunk; with MaxUnacked=1 the Write must block until
	// the first chunk is acked.
	blocked := make(chan struct{})
	go func() {
		_, _ = w.Write([]byte("b"))
		close(blocked)
	}()

	select {
	case <-blocked:
		t.Fatal("Write returned while the unacked buffer was full — output not backpressured")
	case <-time.After(50 * time.Millisecond):
		// Good: the writer is backpressured.
	}

	close(gate) // drain acks; the blocked write proceeds.
	select {
	case <-blocked:
	case <-time.After(2 * time.Second):
		t.Fatal("Write stayed blocked after acks drained")
	}

	if err := s.Close(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}
}
