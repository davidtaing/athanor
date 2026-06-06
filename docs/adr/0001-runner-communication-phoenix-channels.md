---
status: accepted
---

# Runners connect over Phoenix Channels (persistent WebSocket)

Runners need registration, job dispatch, log streaming, heartbeats, and
cancellation. Rather than HTTP polling (each of those becomes a separate
bolt-on mechanism, and cancellation degrades to "next check-in"), runners hold
a persistent WebSocket to the control plane using the Phoenix Channels wire
protocol. The Go runner uses a Channels client library rather than a
hand-rolled protocol.

## Considered options

- **HTTP poll / long-poll** (how GitHub Actions runners work) — rejected:
  every protocol feature needs its own sub-design; no push semantics for
  dispatch acks or cancellation.
- **gRPC bidirectional streaming** — rejected: first-class in Go but
  second-class in Elixir (`elixir-grpc` is community-maintained, no OTP
  connection-lifecycle integration). The Elixir control plane is the core of
  the project; the first-class technology belongs there.
- **Raw WebSocket with a hand-designed message protocol** — deferred, not
  rejected. Maximum learning value (protocol design from scratch) but a
  significant time sink. Revisit once the MVP works; the transport decision
  (WebSocket) survives that swap — only the framing changes.

## Consequences

- A dropped connection is a liveness *signal*, not proof of runner death:
  jobs on a disconnected runner need a grace period before being declared
  lost.
- The Go runner couples to the Phoenix Channels wire format via a
  thinly-maintained client ecosystem (e.g. `nshafer/phx`); acceptable for MVP,
  one of the reasons 2b stays on the table.
