// Package protocol is a minimal Phoenix Channels client for the v1 Runner
// protocol (docs/prd/runner-protocol.md, ADR 0001). It speaks the Phoenix V2
// serializer wire format — each frame is a JSON array
// [join_ref, ref, topic, event, payload] — over a single WebSocket.
//
// Scope is the v0 subset of the v1 catalog that issue #5 builds: first join
// with a Boot Token, receiving job:assign, sending job:started and
// job:finished. Rejoin with a Session Token, log:chunk, and job:cancel are
// reserved (issues #8/#10/#11); the wire shapes here do not foreclose them.
package protocol

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"strconv"
	"sync"

	"github.com/gorilla/websocket"
)

// JoinReply is the control-plane's reply to a join. SessionToken is present on
// first join only; Verdict is "continue" or "stop".
type JoinReply struct {
	ProtocolVersion string `json:"protocol_version"`
	SessionToken    string `json:"session_token"`
	Verdict         string `json:"verdict"`
}

// Push is a control-plane -> Runner message that is not a reply (e.g.
// job:assign, job:cancel).
type Push struct {
	Event   string
	Payload json.RawMessage
}

// Dialer abstracts establishing the WebSocket, so tests can substitute one.
type Dialer interface {
	Dial(ctx context.Context, url string) (Conn, error)
}

// Conn is the subset of a WebSocket connection the client uses.
type Conn interface {
	ReadMessage() (messageType int, p []byte, err error)
	WriteMessage(messageType int, data []byte) error
	Close() error
}

// Client holds one WebSocket to the control plane and multiplexes replies and
// server pushes over it.
type Client struct {
	url      string
	runnerID string
	dialer   Dialer

	mu       sync.Mutex
	conn     Conn
	joinRef  string
	refSeq   int
	pending  map[string]chan replyResult
	pushes   chan Push
	closed   bool
	readDone chan struct{}
}

type replyResult struct {
	status   string
	response json.RawMessage
}

const topicPrefix = "runner:v1:"

// NewClient returns a Client for the given control-plane WebSocket URL and
// Runner id. The URL is the socket endpoint (e.g. ws://host/runner/websocket);
// the Phoenix vsn query param is appended automatically.
func NewClient(rawURL, runnerID string) *Client {
	return &Client{
		url:      rawURL,
		runnerID: runnerID,
		dialer:   gorillaDialer{},
		pending:  make(map[string]chan replyResult),
		pushes:   make(chan Push, 16),
		readDone: make(chan struct{}),
	}
}

// Topic is the channel topic this client joins.
func (c *Client) Topic() string { return topicPrefix + c.runnerID }

// Pushes returns the channel of server pushes (job:assign, job:cancel, ...).
func (c *Client) Pushes() <-chan Push { return c.pushes }

// JoinWithBootToken connects (if not already) and performs a first join with
// the Boot Token, returning the join reply. A rejected join is a hard error —
// the caller fails fast (PRD: rejected join ⇒ Runner exits nonzero).
func (c *Client) JoinWithBootToken(ctx context.Context, bootToken string) (JoinReply, error) {
	return c.join(ctx, map[string]string{"boot_token": bootToken})
}

func (c *Client) join(ctx context.Context, params map[string]string) (JoinReply, error) {
	if err := c.ensureConn(ctx); err != nil {
		return JoinReply{}, err
	}

	c.mu.Lock()
	c.joinRef = c.nextRef()
	joinRef := c.joinRef
	c.mu.Unlock()

	payload, _ := json.Marshal(params)
	res, err := c.request(ctx, joinRef, "phx_join", payload)
	if err != nil {
		return JoinReply{}, err
	}
	if res.status != "ok" {
		return JoinReply{}, fmt.Errorf("join rejected: %s", string(res.response))
	}

	var reply JoinReply
	if err := json.Unmarshal(res.response, &reply); err != nil {
		return JoinReply{}, fmt.Errorf("decode join reply: %w", err)
	}
	return reply, nil
}

// Send sends a Runner -> control-plane message that expects an ack reply and
// blocks until the ack arrives (or ctx is done). job:started and job:finished
// use this; the control plane acks every Runner transition (PRD invariant 2).
func (c *Client) Send(ctx context.Context, event string, payload any) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	c.mu.Lock()
	ref := c.nextRef()
	c.mu.Unlock()

	res, err := c.request(ctx, ref, event, raw)
	if err != nil {
		return err
	}
	if res.status != "ok" {
		return fmt.Errorf("%s rejected: %s", event, string(res.response))
	}
	return nil
}

func (c *Client) request(ctx context.Context, ref, event string, payload json.RawMessage) (replyResult, error) {
	ch := make(chan replyResult, 1)
	c.mu.Lock()
	c.pending[ref] = ch
	frame := c.encodeLocked(ref, event, payload)
	conn := c.conn
	c.mu.Unlock()

	if err := conn.WriteMessage(websocket.TextMessage, frame); err != nil {
		c.mu.Lock()
		delete(c.pending, ref)
		c.mu.Unlock()
		return replyResult{}, err
	}

	select {
	case res := <-ch:
		return res, nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, ref)
		c.mu.Unlock()
		return replyResult{}, ctx.Err()
	case <-c.readDone:
		return replyResult{}, fmt.Errorf("connection closed awaiting reply to %s", event)
	}
}

func (c *Client) ensureConn(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		return nil
	}
	conn, err := c.dialer.Dial(ctx, withVsn(c.url))
	if err != nil {
		return err
	}
	c.conn = conn
	go c.readLoop(conn)
	return nil
}

func (c *Client) readLoop(conn Conn) {
	defer close(c.readDone)
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return
		}
		c.dispatch(raw)
	}
}

func (c *Client) dispatch(raw []byte) {
	var arr [5]json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return
	}
	var ref *string
	var event string
	_ = json.Unmarshal(arr[1], &ref)
	_ = json.Unmarshal(arr[3], &event)
	payload := arr[4]

	if event == "phx_reply" {
		var p struct {
			Status   string          `json:"status"`
			Response json.RawMessage `json:"response"`
		}
		_ = json.Unmarshal(payload, &p)
		if ref == nil {
			return
		}
		c.mu.Lock()
		ch, ok := c.pending[*ref]
		delete(c.pending, *ref)
		c.mu.Unlock()
		if ok {
			ch <- replyResult{status: p.Status, response: p.Response}
		}
		return
	}

	// A server push (job:assign, job:cancel, ...).
	select {
	case c.pushes <- Push{Event: event, Payload: payload}:
	default:
		// Buffer (cap 16) is full: the consumer is not draining fast enough.
		// We drop the push rather than block the readLoop. Logging the drop
		// makes it visible; backpressure/blocking is deferred to issue #8,
		// once push volume (log:chunk) is real.
		log.Printf("protocol: dropped server push, buffer full (event=%s topic=%s)", event, c.Topic())
	}
}

func (c *Client) encodeLocked(ref, event string, payload json.RawMessage) []byte {
	if payload == nil {
		payload = json.RawMessage("{}")
	}
	arr := []any{c.joinRef, ref, c.Topic(), event, payload}
	raw, _ := json.Marshal(arr)
	return raw
}

func (c *Client) nextRef() string {
	c.refSeq++
	return strconv.Itoa(c.refSeq)
}

// Close closes the underlying connection.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.conn == nil {
		c.closed = true
		return nil
	}
	c.closed = true
	return c.conn.Close()
}

func withVsn(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return rawURL
	}
	q := u.Query()
	if q.Get("vsn") == "" {
		q.Set("vsn", "2.0.0")
	}
	u.RawQuery = q.Encode()
	return u.String()
}

// gorillaDialer is the production Dialer.
type gorillaDialer struct{}

func (gorillaDialer) Dial(ctx context.Context, rawURL string) (Conn, error) {
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, rawURL, nil)
	if err != nil {
		return nil, err
	}
	return conn, nil
}
