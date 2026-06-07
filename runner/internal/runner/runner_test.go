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

// scriptedCP is a fake control plane that drives the full v1 protocol path:
// reply to join, push job:assign (with Step objects), ack job:ack, job:started
// and job:finished, recording the order of inbound events and the finished
// payload.
type scriptedCP struct {
	// steps are Step objects {command, name?} as they cross the wire (PRD #35).
	steps []map[string]any

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

	// 3. job:ack, job:started, then job:finished — ack each.
	for {
		f := read()
		s.gotEvents = append(s.gotEvents, f.Event)
		switch f.Event {
		case "job:ack":
			reply(f, "ok", map[string]any{})
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

// TestRunFailsFastOnUnknownJoinVerdict: a verdict outside the catalog
// ("continue"/"stop") is a protocol violation; the runner must exit
// deterministically instead of hanging in awaitAssign.
func TestRunFailsFastOnUnknownJoinVerdict(t *testing.T) {
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		t.Helper()
		_, raw, err := ws.ReadMessage()
		if err != nil {
			t.Fatalf("server read: %v", err)
		}
		join := decodeFrame(t, raw)
		respRaw, _ := json.Marshal(map[string]any{
			"status": "ok",
			"response": map[string]any{
				"protocol_version": "v1",
				"session_token":    "sess-1",
				"verdict":          "maybe",
			},
		})
		out := v2Frame{JoinRef: join.JoinRef, Ref: join.Ref, Topic: join.Topic, Event: "phx_reply", Payload: respRaw}
		if err := ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out)); err != nil {
			t.Fatalf("server write: %v", err)
		}
	})
	defer srv.Close()

	exec := executor.StubRunner(func(_ context.Context, _ executor.Step) (int, error) {
		t.Fatal("no step should run on an unknown verdict")
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
	if err == nil || !strings.Contains(err.Error(), `unsupported join verdict "maybe"`) {
		t.Fatalf("err = %v, want unsupported join verdict", err)
	}
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
}

// TestRunExitsNonzeroOnInvalidCredentials: an invalid_credentials rejection is
// fatal — the runner exits nonzero immediately, without retrying (PRD #35).
func TestRunExitsNonzeroOnInvalidCredentials(t *testing.T) {
	var joinAttempts int
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		t.Helper()
		for {
			_, raw, err := ws.ReadMessage()
			if err != nil {
				return
			}
			f := decodeFrame(t, raw)
			joinAttempts++
			respRaw, _ := json.Marshal(map[string]any{
				"status": "error",
				"response": map[string]any{
					"protocol_version": "v1",
					"reason":           "invalid_credentials",
				},
			})
			out := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
			_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out))
		}
	})
	defer srv.Close()

	exec := executor.StubRunner(func(_ context.Context, _ executor.Step) (int, error) {
		t.Fatal("no step should run on a fatal rejection")
		return 0, nil
	})

	r := New(Config{URL: wsURL(srv.URL), RunnerID: "runner-1", BootToken: "bad"}, exec)
	r.joinBackoff = time.Millisecond

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	code, err := r.Run(ctx)
	if err == nil {
		t.Fatal("Run err = nil, want non-nil for a fatal rejection")
	}
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if joinAttempts != 1 {
		t.Fatalf("join attempts = %d, want 1 — invalid_credentials must not retry", joinAttempts)
	}
}

// TestRunRetriesOnTryAgain: a try_again rejection is transient — the runner
// retries the join with a fixed backoff until it is accepted (PRD #35).
func TestRunRetriesOnTryAgain(t *testing.T) {
	const rejectTimes = 2
	cp := &scriptedCP{steps: []map[string]any{{"command": "make"}}}

	var joinAttempts int
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		t.Helper()
		// Reject the first `rejectTimes` joins with try_again, then run the full
		// happy path on the next join.
		for joinAttempts < rejectTimes {
			_, raw, err := ws.ReadMessage()
			if err != nil {
				return
			}
			f := decodeFrame(t, raw)
			joinAttempts++
			respRaw, _ := json.Marshal(map[string]any{
				"status": "error",
				"response": map[string]any{
					"protocol_version": "v1",
					"reason":           "try_again",
				},
			})
			out := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
			_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, out))
		}
		joinAttempts++
		cp.handle(t, ws)
	})
	defer srv.Close()

	exec := executor.StubRunner(func(_ context.Context, _ executor.Step) (int, error) { return 0, nil })

	r := New(Config{URL: wsURL(srv.URL), RunnerID: "runner-1", BootToken: "boot-1"}, exec)
	r.joinBackoff = time.Millisecond

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	code, err := r.Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if joinAttempts != rejectTimes+1 {
		t.Fatalf("join attempts = %d, want %d (retried past the try_agains)", joinAttempts, rejectTimes+1)
	}
}

func TestRunJobHappyPath(t *testing.T) {
	cp := &scriptedCP{steps: []map[string]any{
		{"command": "make", "name": "compile"},
		{"command": "make test"},
	}}
	srv := newFakeServer(t, cp.handle)
	defer srv.Close()

	var ranCommands []string
	exec := executor.StubRunner(func(_ context.Context, st executor.Step) (int, error) {
		ranCommands = append(ranCommands, st.Run)
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

	// job:ack precedes job:started (PRD #35: ack delivery before reporting start).
	wantOrder := []string{"phx_join", "job:ack", "job:started", "job:finished"}
	if strings.Join(cp.gotEvents, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("event order = %v, want %v", cp.gotEvents, wantOrder)
	}
	// The executor runs each Step's `command` (the object's command field).
	if strings.Join(ranCommands, ",") != "make,make test" {
		t.Fatalf("ran commands = %v, want [make, make test]", ranCommands)
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
	cp := &scriptedCP{steps: []map[string]any{
		{"command": "ok"},
		{"command": "boom"},
		{"command": "never"},
	}}
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
