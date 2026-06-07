package runner

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/davidtaing/athanor/runner/internal/executor"
	"github.com/gorilla/websocket"
)

// streamingCP is a fake control plane for the log path: it drives join/assign,
// acks job:ack/job:started, and records every log:chunk (acking each) and the
// order of all client events — so a test can assert job:finished lands only
// after every log:chunk is acked.
type streamingCP struct {
	steps []map[string]any

	mu         sync.Mutex
	events     []string
	chunks     []map[string]any
	finishedAt int
}

func (s *streamingCP) handle(t *testing.T, ws *websocket.Conn) {
	t.Helper()
	reply := func(f v2Frame, status string, response any) {
		respRaw, _ := json.Marshal(map[string]any{"status": status, "response": response})
		out := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
		_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out))
	}

	// join
	_, raw, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("read join: %v", err)
	}
	join := decodeFrame(t, raw)
	reply(join, "ok", map[string]any{
		"protocol_version": "v1", "session_token": "sess-1", "verdict": "continue",
	})

	// push job:assign with a small byte cap so output splits into several chunks.
	pl, _ := json.Marshal(map[string]any{
		"job_id": "job-1", "git_url": "https://example.com/repo.git", "git_ref": "main",
		"steps": s.steps, "env": map[string]string{},
		"log": map[string]any{"max_bytes": 8, "max_interval": 50},
	})
	out := v2Frame{JoinRef: join.JoinRef, Ref: nil, Topic: join.Topic, Event: "job:assign", Payload: pl}
	_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out))

	for {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			return
		}
		f := decodeFrame(t, raw)
		s.mu.Lock()
		s.events = append(s.events, f.Event)
		switch f.Event {
		case "log:chunk":
			var c map[string]any
			_ = json.Unmarshal(f.Payload, &c)
			s.chunks = append(s.chunks, c)
		case "job:finished":
			s.finishedAt = len(s.events)
		}
		s.mu.Unlock()

		reply(f, "ok", map[string]any{})
		if f.Event == "job:finished" {
			return
		}
	}
}

func (s *streamingCP) snapshot() ([]string, []map[string]any, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ev := append([]string(nil), s.events...)
	ch := append([]map[string]any(nil), s.chunks...)
	return ev, ch, s.finishedAt
}

// TestStreamsStepOutputAsChunksBeforeFinished: a Step's stdout is shipped as
// batched log:chunk messages carrying seq+step_index, and job:finished is the
// last event — sent only after every log:chunk has been acked (PRD: "nothing
// is lost when the Runner is destroyed").
func TestStreamsStepOutputAsChunksBeforeFinished(t *testing.T) {
	cp := &streamingCP{steps: []map[string]any{
		{"command": "printf 'abcdefghijklmnop'"}, // 16 bytes, 8-byte cap → 2 chunks
	}}
	srv := newFakeServer(t, cp.handle)
	defer srv.Close()

	// Real shell runner so actual Step output flows through the streamer.
	r := New(Config{URL: wsURL(srv.URL), RunnerID: "runner-1", BootToken: "boot-1"},
		executor.NewShellRunner())

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	code, err := r.Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}

	events, chunks, finishedAt := cp.snapshot()

	if len(chunks) == 0 {
		t.Fatal("no log:chunk received — Step output was not streamed")
	}
	// job:finished is the final event (all chunks acked before it).
	if finishedAt != len(events) {
		t.Fatalf("job:finished at %d of %d events — chunks must all precede it: %v",
			finishedAt, len(events), events)
	}
	if last := events[len(events)-1]; last != "job:finished" {
		t.Fatalf("last event = %q, want job:finished", last)
	}

	// Chunks carry monotonic seq (1..N) and step_index 0, and reassemble.
	var joined string
	for i, c := range chunks {
		seq, _ := c["seq"].(float64)
		if int(seq) != i+1 {
			t.Fatalf("chunk %d seq = %v, want %d", i, c["seq"], i+1)
		}
		if si, _ := c["step_index"].(float64); int(si) != 0 {
			t.Fatalf("chunk %d step_index = %v, want 0", i, c["step_index"])
		}
		joined += c["content"].(string)
	}
	if joined != "abcdefghijklmnop" {
		t.Fatalf("reassembled content = %q, want abcdefghijklmnop", joined)
	}
}
