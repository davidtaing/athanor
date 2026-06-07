package protocol

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// v2Frame is one Phoenix Channels V2 wire frame: a JSON array
// [join_ref, ref, topic, event, payload]. The fake control-plane server in
// these tests encodes/decodes it to match the real Channel exactly.
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

func TestJoinFirstReturnsSessionToken(t *testing.T) {
	const runnerID = "runner-123"
	const bootToken = "boot-abc"

	var gotJoin v2Frame
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			t.Fatalf("server read: %v", err)
		}
		gotJoin = decodeFrame(t, raw)

		// Reply to the join with the v1 first-join shape.
		resp := map[string]any{
			"status": "ok",
			"response": map[string]any{
				"protocol_version": "v1",
				"session_token":    "sess-xyz",
				"verdict":          "continue",
			},
		}
		respRaw, _ := json.Marshal(resp)
		reply := v2Frame{
			JoinRef: gotJoin.JoinRef,
			Ref:     gotJoin.Ref,
			Topic:   gotJoin.Topic,
			Event:   "phx_reply",
			Payload: respRaw,
		}
		if err := ws.WriteMessage(websocket.TextMessage, encodeFrame(t, reply)); err != nil {
			t.Fatalf("server write reply: %v", err)
		}
	})
	defer srv.Close()

	client := NewClient(wsURL(srv.URL), runnerID)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	joined, err := client.JoinWithBootToken(ctx, bootToken)
	if err != nil {
		t.Fatalf("JoinWithBootToken: %v", err)
	}

	if want := "runner:v1:" + runnerID; gotJoin.Topic != want {
		t.Errorf("join topic = %q, want %q", gotJoin.Topic, want)
	}
	if gotJoin.Event != "phx_join" {
		t.Errorf("join event = %q, want phx_join", gotJoin.Event)
	}
	var joinPayload struct {
		BootToken string `json:"boot_token"`
	}
	if err := json.Unmarshal(gotJoin.Payload, &joinPayload); err != nil {
		t.Fatalf("join payload: %v", err)
	}
	if joinPayload.BootToken != bootToken {
		t.Errorf("join boot_token = %q, want %q", joinPayload.BootToken, bootToken)
	}
	if joined.ProtocolVersion != "v1" {
		t.Errorf("protocol_version = %q, want v1", joined.ProtocolVersion)
	}
	if joined.SessionToken != "sess-xyz" {
		t.Errorf("session_token = %q, want sess-xyz", joined.SessionToken)
	}
	if joined.Verdict != "continue" {
		t.Errorf("verdict = %q, want continue", joined.Verdict)
	}
}

func TestJoinRejectedFailsFast(t *testing.T) {
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			return
		}
		f := decodeFrame(t, raw)
		resp := map[string]any{
			"status": "error",
			"response": map[string]any{
				"protocol_version": "v1",
				"reason":           "invalid_credentials",
			},
		}
		respRaw, _ := json.Marshal(resp)
		reply := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
		_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, reply))
	})
	defer srv.Close()

	client := NewClient(wsURL(srv.URL), "runner-1")
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, err := client.JoinWithBootToken(ctx, "bad")
	if err == nil {
		t.Fatal("JoinWithBootToken err = nil, want non-nil for a rejected join")
	}
	// The rejection is surfaced as a typed error carrying the coarse code, so the
	// caller can branch fatal vs retry (PRD #35).
	var rej *JoinRejectedError
	if !errors.As(err, &rej) {
		t.Fatalf("error = %v (%T), want *JoinRejectedError", err, err)
	}
	if rej.Reason != ReasonInvalidCredentials {
		t.Errorf("reason = %q, want %q", rej.Reason, ReasonInvalidCredentials)
	}
}

func TestJoinRejectedTryAgainCarriesCode(t *testing.T) {
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			return
		}
		f := decodeFrame(t, raw)
		resp := map[string]any{
			"status": "error",
			"response": map[string]any{
				"protocol_version": "v1",
				"reason":           "try_again",
			},
		}
		respRaw, _ := json.Marshal(resp)
		reply := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
		_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, reply))
	})
	defer srv.Close()

	client := NewClient(wsURL(srv.URL), "runner-1")
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, err := client.JoinWithBootToken(ctx, "tok")
	var rej *JoinRejectedError
	if !errors.As(err, &rej) {
		t.Fatalf("error = %v (%T), want *JoinRejectedError", err, err)
	}
	if rej.Reason != ReasonTryAgain {
		t.Errorf("reason = %q, want %q", rej.Reason, ReasonTryAgain)
	}
}

func TestPushesClosesOnConnectionClose(t *testing.T) {
	srv := newFakeServer(t, func(t *testing.T, ws *websocket.Conn) {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			return
		}
		f := decodeFrame(t, raw)
		resp := map[string]any{
			"status": "ok",
			"response": map[string]any{
				"protocol_version": "v1",
				"session_token":    "sess-xyz",
				"verdict":          "continue",
			},
		}
		respRaw, _ := json.Marshal(resp)
		reply := v2Frame{JoinRef: f.JoinRef, Ref: f.Ref, Topic: f.Topic, Event: "phx_reply", Payload: respRaw}
		_ = ws.WriteMessage(websocket.TextMessage, encodeFrame(t, reply))
		// Close the WebSocket from the server side; readLoop should observe the
		// read error and close the pushes channel.
	})
	defer srv.Close()

	client := NewClient(wsURL(srv.URL), "runner-1")
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	if _, err := client.JoinWithBootToken(ctx, "boot"); err != nil {
		t.Fatalf("JoinWithBootToken: %v", err)
	}

	// The server handler has returned, closing the connection. The pushes
	// channel must close so consumers see the !ok path rather than blocking.
	select {
	case _, ok := <-client.Pushes():
		if ok {
			t.Fatal("Pushes() yielded a value, want closed channel on connection close")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Pushes() did not close after the server closed the connection")
	}
}

// --- helpers ---

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
