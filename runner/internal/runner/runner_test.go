package runner

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/davidtaing/athanor/runner/internal/executor"
	"github.com/gorilla/websocket"
)

// scriptedCP is a fake control plane that drives the full v0 protocol path:
// reply to join, push job:assign, ack job:started and job:finished, recording
// the order of inbound events and the finished payload.
type scriptedCP struct {
	steps []string

	gotEvents   []string
	finishedRaw json.RawMessage
}

func (s *scriptedCP) handle(t *testing.T, ws *websocket.Conn) {
	t.Helper()
	read := func() v2Frame {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			t.Fatalf("server read: %v", err)
		}
		return decodeFrame(t, raw)
	}
	reply := func(f v2Frame, status string, response any) {
		respRaw, _ := json.Marshal(map[string]any{"status": status, "response": response})
		out := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
		if err := ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out)); err != nil {
			t.Fatalf("server write: %v", err)
		}
	}
	push := func(joinRef *string, topic, event string, payload any) {
		pl, _ := json.Marshal(payload)
		out := v2Frame{JoinRef: joinRef, Ref: nil, Topic: topic, Event: event, Payload: pl}
		if err := ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out)); err != nil {
			t.Fatalf("server push: %v", err)
		}
	}

	// 1. join
	join := read()
	s.gotEvents = append(s.gotEvents, join.Event)
	reply(join, "ok", map[string]any{
		"protocol_version": "v1",
		"session_token":    "sess-1",
		"verdict":          "continue",
	})

	// 2. push job:assign
	push(join.JoinRef, join.Topic, "job:assign", map[string]any{
		"job_id":  "job-1",
		"git_url": "https://example.com/repo.git",
		"git_ref": "main",
		"steps":   s.steps,
		"env":     map[string]string{},
		"log":     map[string]any{"max_bytes": 65536, "max_interval": 1000},
	})

	// 3. job:started, then job:finished — ack both.
	for {
		f := read()
		s.gotEvents = append(s.gotEvents, f.Event)
		switch f.Event {
		case "job:started":
			reply(f, "ok", map[string]any{})
		case "job:finished":
			s.finishedRaw = f.Payload
			reply(f, "ok", map[string]any{})
			return
		default:
			t.Fatalf("unexpected client event %q", f.Event)
		}
	}
}

func TestRunJobHappyPath(t *testing.T) {
	cp := &scriptedCP{steps: []string{"step-a", "step-b"}}
	srv := newFakeServer(t, cp.handle)
	defer srv.Close()

	var ranIdx []int
	exec := executor.StubRunner(func(_ context.Context, st executor.Step) (int, error) {
		ranIdx = append(ranIdx, len(ranIdx))
		_ = st
		return 0, nil
	})

	r := New(Config{
		URL:       wsURL(srv.URL),
		RunnerID:  "runner-1",
		BootToken: "boot-1",
	}, exec)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	code, err := r.Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}

	wantOrder := []string{"phx_join", "job:started", "job:finished"}
	if strings.Join(cp.gotEvents, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("event order = %v, want %v", cp.gotEvents, wantOrder)
	}
	if len(ranIdx) != 2 {
		t.Fatalf("ran %d steps, want 2", len(ranIdx))
	}

	var fin struct {
		ExitCode        int  `json:"exit_code"`
		FailedStepIndex *int `json:"failed_step_index,omitempty"`
	}
	if err := json.Unmarshal(cp.finishedRaw, &fin); err != nil {
		t.Fatalf("decode finished: %v", err)
	}
	if fin.ExitCode != 0 {
		t.Errorf("finished exit_code = %d, want 0", fin.ExitCode)
	}
	if fin.FailedStepIndex != nil {
		t.Errorf("finished failed_step_index = %v, want absent", fin.FailedStepIndex)
	}
}

func TestRunJobFailingStepReportsNonzeroAndStops(t *testing.T) {
	cp := &scriptedCP{steps: []string{"ok", "boom", "never"}}
	srv := newFakeServer(t, cp.handle)
	defer srv.Close()

	var ran int
	exec := executor.StubRunner(func(_ context.Context, st executor.Step) (int, error) {
		ran++
		if st.Run == "boom" {
			return 5, nil
		}
		return 0, nil
	})

	r := New(Config{URL: wsURL(srv.URL), RunnerID: "runner-1", BootToken: "boot-1"}, exec)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	code, err := r.Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 5 {
		t.Fatalf("exit code = %d, want 5", code)
	}
	if ran != 2 {
		t.Fatalf("ran %d steps, want 2 — must stop after the failing Step", ran)
	}

	var fin struct {
		ExitCode        int  `json:"exit_code"`
		FailedStepIndex *int `json:"failed_step_index"`
	}
	if err := json.Unmarshal(cp.finishedRaw, &fin); err != nil {
		t.Fatalf("decode finished: %v", err)
	}
	if fin.ExitCode != 5 {
		t.Errorf("finished exit_code = %d, want 5", fin.ExitCode)
	}
	if fin.FailedStepIndex == nil || *fin.FailedStepIndex != 1 {
		t.Errorf("finished failed_step_index = %v, want 1", fin.FailedStepIndex)
	}
}

// --- shared test helpers (Channels V2 framing for the fake server) ---

type v2Frame struct {
	JoinRef *string
	Ref     *string
	Topic   string
	Event   string
	Payload json.RawMessage
}

func decodeFrame(t *testing.T, raw []byte) v2Frame {
	t.Helper()
	var arr [5]json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		t.Fatalf("decode V2 frame %s: %v", raw, err)
	}
	var f v2Frame
	_ = json.Unmarshal(arr[0], &f.JoinRef)
	_ = json.Unmarshal(arr[1], &f.Ref)
	_ = json.Unmarshal(arr[2], &f.Topic)
	_ = json.Unmarshal(arr[3], &f.Event)
	f.Payload = arr[4]
	return f
}

func encodeFrame(t *testing.T, f v2Frame) []byte {
	t.Helper()
	arr := []any{f.JoinRef, f.Ref, f.Topic, f.Event, f.Payload}
	raw, err := json.Marshal(arr)
	if err != nil {
		t.Fatalf("encode frame: %v", err)
	}
	return raw
}

func newFakeServer(t *testing.T, handle func(*testing.T, *websocket.Conn)) *httptest.Server {
	t.Helper()
	up := websocket.Upgrader{}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		defer func() { _ = ws.Close() }()
		handle(t, ws)
	}))
}

func wsURL(httpURL string) string {
	return "ws" + strings.TrimPrefix(httpURL, "http")
}
