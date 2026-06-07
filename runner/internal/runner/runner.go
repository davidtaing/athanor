// Package runner orchestrates one Job for one process lifetime: join the
// control plane with the Boot Token, receive the job:assign push, report
// job:started, run the Job's Steps through the executor, report job:finished
// with the exit status, then return so the process can exit. One Job per
// process — the runner never loops (ADR 0003, issue #5).
package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/davidtaing/athanor/runner/internal/executor"
	"github.com/davidtaing/athanor/runner/internal/logstream"
	"github.com/davidtaing/athanor/runner/internal/protocol"
	"github.com/davidtaing/athanor/runner/internal/workspace"
)

// Config is the runner's startup configuration, read from the environment by
// the binary (control-plane URL, Runner id, Boot Token).
type Config struct {
	URL       string
	RunnerID  string
	BootToken string
}

// channel is the protocol surface the runner needs; the real one is
// *protocol.Client. Defined here so the runner can be exercised without a real
// socket if needed.
type channel interface {
	JoinWithBootToken(ctx context.Context, bootToken string) (protocol.JoinReply, error)
	Pushes() <-chan protocol.Push
	Send(ctx context.Context, event string, payload any) error
	Close() error
}

// defaultJoinBackoff is the fixed short delay between join retries after a
// try_again rejection (PRD #35: a dumb bounded backoff — the boot timeout, via
// the caller's context, bounds the total).
const defaultJoinBackoff = 2 * time.Second

// Runner wires the protocol client to the executor for a single Job.
type Runner struct {
	cfg  Config
	exec executor.StepRunner
	ch   channel
	log  *slog.Logger

	// joinBackoff is the fixed delay between join retries on try_again. Set in
	// tests; defaults to defaultJoinBackoff.
	joinBackoff time.Duration

	// clone checks out the Job's repo before any Step runs. Defaults to
	// workspace.Clone (real git); tests inject a stub to avoid the network.
	clone func(ctx context.Context, spec workspace.Spec) workspace.Result
	// runnerFor produces the StepRunner that runs the Job's Steps from the
	// cloned workspace directory. Defaults to a ShellRunner rooted at dir;
	// tests inject a stub StepRunner while capturing dir.
	runnerFor func(dir string) executor.StepRunner
}

// assignPayload is the job:assign payload (docs/prd/runner-protocol.md). steps
// is an ordered list of Step objects (PRD #35); no image (the Runner is already
// inside it) and no timeout (control-plane enforced).
type assignPayload struct {
	JobID  string            `json:"job_id"`
	GitURL string            `json:"git_url"`
	GitRef string            `json:"git_ref"`
	Steps  []step            `json:"steps"`
	Env    map[string]string `json:"env"`
	Log    logConfig         `json:"log"`
}

// logConfig is the log batching config delivered in job:assign — tuning is
// control-plane config, never a runner image rebuild (PRD log-streaming).
// max_interval is milliseconds on the wire.
type logConfig struct {
	MaxBytes      int `json:"max_bytes"`
	MaxIntervalMs int `json:"max_interval"`
}

// step is a Step object {command (required), name (optional)} (PRD #35). The
// runner executes `command`; display falls back to `command` when `name` is
// empty.
type step struct {
	Command string `json:"command"`
	Name    string `json:"name,omitempty"`
}

// displayName is the Step's name, falling back to its command (PRD #35).
func (s step) displayName() string {
	if s.Name != "" {
		return s.Name
	}
	return s.Command
}

// finishedPayload is the job:finished payload — facts only, no verdict. The
// control plane derives the verdict (exit 0 ⇒ succeeded; nonzero ⇒ failed,
// reason nonzero_exit).
type finishedPayload struct {
	ExitCode        int  `json:"exit_code"`
	FailedStepIndex *int `json:"failed_step_index,omitempty"`
}

// New returns a Runner that dials the configured URL.
//
// exec is the StepRunner used to run the Job's Steps. When it is a
// *executor.ShellRunner (the production case), New roots it at the cloned
// workspace directory so Steps run from the checkout; other StepRunners (test
// stubs) are used as-is.
func New(cfg Config, exec executor.StepRunner) *Runner {
	return &Runner{
		cfg:         cfg,
		exec:        exec,
		ch:          protocol.NewClient(cfg.URL, cfg.RunnerID),
		log:         slog.Default(),
		joinBackoff: defaultJoinBackoff,
		clone:       workspace.Clone,
		runnerFor: func(dir string) executor.StepRunner {
			if sh, ok := exec.(*executor.ShellRunner); ok {
				sh.Dir = dir
			}
			return exec
		},
	}
}

// Run executes the full single-Job lifecycle and returns the Job's exit code.
// The returned error is reserved for protocol/transport failures (a failing
// Step is reported via the exit code, not an error). The caller exits the
// process with the returned code.
func (r *Runner) Run(ctx context.Context) (int, error) {
	defer func() { _ = r.ch.Close() }()

	joined, err := r.joinWithRetry(ctx)
	if err != nil {
		// A definitively rejected (invalid_credentials) or otherwise failed join
		// exits nonzero. A try_again rejection is retried inside joinWithRetry;
		// only an exhausted/fatal join reaches here (PRD #35).
		return 1, fmt.Errorf("join: %w", err)
	}
	r.log.Info("joined control plane",
		"protocol_version", joined.ProtocolVersion, "verdict", joined.Verdict)

	switch joined.Verdict {
	case "continue":
		// Proceed to await assignment.
	case "stop":
		// The Job went terminal while we were away — nothing to run.
		return 0, nil
	default:
		// An unknown verdict is a protocol violation — fail fast rather than
		// hang in awaitAssign for an assignment that may never come.
		return 1, fmt.Errorf("unsupported join verdict %q", joined.Verdict)
	}

	assign, err := r.awaitAssign(ctx)
	if err != nil {
		return 1, err
	}
	r.log.Info("job assigned", "job_id", assign.JobID, "steps", len(assign.Steps))

	// Acknowledge delivery of the assignment before reporting start (PRD #35).
	// job:ack is an ordinary client push; the control plane stamps the Job so its
	// rejoin re-send rule never re-dispatches work we already hold.
	if err := r.ch.Send(ctx, "job:ack", map[string]any{}); err != nil {
		return 1, fmt.Errorf("job:ack: %w", err)
	}

	if err := r.ch.Send(ctx, "job:started", map[string]any{}); err != nil {
		return 1, fmt.Errorf("job:started: %w", err)
	}

	// Stream Step (and clone) output as batched, sequenced log:chunk over the
	// Channel (PRD log-streaming). The batching limits come from job:assign,
	// never the image. Close drains every chunk's ack before we report
	// job:finished — that ordering is what makes "nothing is lost when the
	// Runner is destroyed" true.
	streamer := logstream.New(chunkSender{ch: r.ch}, logstream.Config{
		MaxBytes:    assign.Log.MaxBytes,
		MaxInterval: time.Duration(assign.Log.MaxIntervalMs) * time.Millisecond,
	})

	result, err := r.runJob(ctx, assign, streamer)
	if err != nil {
		return 1, err
	}

	if err := streamer.Close(ctx); err != nil {
		return 1, fmt.Errorf("log stream: %w", err)
	}

	finished := finishedPayload{
		ExitCode:        result.ExitCode,
		FailedStepIndex: result.FailedStepIndex,
	}
	if err := r.ch.Send(ctx, "job:finished", finished); err != nil {
		return 1, fmt.Errorf("job:finished: %w", err)
	}

	return result.ExitCode, nil
}

// outputSetter is implemented by a StepRunner whose Step output can be directed
// to a writer per Step (the production *executor.ShellRunner). A StepRunner that
// does not implement it (e.g. the test StubRunner) simply produces no streamed
// output — the protocol path is exercised regardless.
type outputSetter interface {
	SetOutput(io.Writer)
}

// runSteps runs steps in order through the given StepRunner (rooted at the
// checkout), directing each Step's output to its own streamer writer (so chunks
// carry the right step_index), and stopping at the first nonzero exit — the
// same semantics as executor.RunSteps.
func (r *Runner) runSteps(ctx context.Context, stepRunner executor.StepRunner, steps []executor.Step, streamer *logstream.Streamer) executor.Result {
	setter, canStream := stepRunner.(outputSetter)

	for i, st := range steps {
		if canStream {
			setter.SetOutput(streamer.StepWriter(i))
		}

		exitCode, err := stepRunner.RunStep(ctx, st)
		if err != nil {
			idx := i
			return executor.Result{ExitCode: 1, FailedStepIndex: &idx}
		}
		if exitCode != 0 {
			idx := i
			return executor.Result{ExitCode: exitCode, FailedStepIndex: &idx}
		}
	}
	return executor.Result{ExitCode: 0}
}

// chunkSender adapts the protocol channel to logstream.Sender: each chunk is a
// log:chunk client push whose ack (the Send reply) means the control plane has
// durably handed it to the LogStore (PRD).
type chunkSender struct {
	ch channel
}

func (s chunkSender) SendChunk(ctx context.Context, c logstream.Chunk) error {
	return s.ch.Send(ctx, "log:chunk", map[string]any{
		"seq":        c.Seq,
		"step_index": c.StepIndex,
		"content":    string(c.Content),
	})
}

// joinWithRetry performs the first join, retrying on a try_again rejection with
// a fixed backoff (PRD #35: dumb bounded backoff). An invalid_credentials
// rejection — or any non-try_again error — is fatal and returned immediately.
// The caller's context (carrying the boot timeout) bounds the total retry time.
func (r *Runner) joinWithRetry(ctx context.Context) (protocol.JoinReply, error) {
	for {
		joined, err := r.ch.JoinWithBootToken(ctx, r.cfg.BootToken)
		if err == nil {
			return joined, nil
		}

		var rej *protocol.JoinRejectedError
		if errors.As(err, &rej) && rej.Reason == protocol.ReasonTryAgain {
			// Transient: retry after a fixed short backoff, unless the context
			// (boot timeout) expires first.
			r.log.Warn("join rejected with try_again; retrying", "backoff", r.joinBackoff)
			select {
			case <-time.After(r.joinBackoff):
				continue
			case <-ctx.Done():
				return protocol.JoinReply{}, ctx.Err()
			}
		}

		// invalid_credentials or any other error is fatal — fail fast.
		return protocol.JoinReply{}, err
	}
}

// runJob clones the Job's repo into a fresh workspace directory, then runs the
// Job's Steps from there, streaming all output (clone and Steps) as log:chunk.
// A clone failure fails the Job cleanly: the captured git output is streamed to
// the log like a failing Step's output, no Step runs, and a nonzero Result is
// returned so job:finished reports a failed Job (issue #7). The control plane
// derives the failed verdict and the Provisioner destroys the container
// regardless.
func (r *Runner) runJob(ctx context.Context, assign assignPayload, streamer *logstream.Streamer) (executor.Result, error) {
	dir, err := os.MkdirTemp("", "athanor-workspace-*")
	if err != nil {
		return executor.Result{}, fmt.Errorf("create workspace: %w", err)
	}
	// The runner is ephemeral (ADR 0003) so the container's filesystem dies with
	// the Job, but clean up the workspace anyway so it never leaks if a future
	// slice reuses the process.
	defer func() { _ = os.RemoveAll(dir) }()
	// The clone target must not pre-exist for `git clone`, so clone into a
	// child of the workspace directory.
	checkout := filepath.Join(dir, "repo")

	cloneRes := r.clone(ctx, workspace.Spec{URL: assign.GitURL, Ref: assign.GitRef, Dir: checkout})
	if cloneRes.Output != "" {
		// Surface git's output in the Job log exactly like Step output, streamed
		// under step_index 0 — the clone is the Job's first observable work,
		// ahead of any Step (PRD log-streaming). A write-to-stream failure must
		// not mask the clone-failure path below, so log and continue.
		if _, err := fmt.Fprint(streamer.StepWriter(0), cloneRes.Output); err != nil {
			r.log.Warn("failed to stream clone output", "err", err)
		}
	}
	if cloneRes.Err != nil {
		r.log.Error("clone failed", "git_url", redactURL(assign.GitURL), "git_ref", assign.GitRef, "err", redactErr(cloneRes.Err))
		// A failed clone fails the Job: a nonzero exit with no Step run. The Job
		// failed before its Steps, so there is no failing Step index.
		return executor.Result{ExitCode: 1}, nil
	}

	// Steps run from the checkout (PRD #35 Step objects: command + optional name).
	steps := make([]executor.Step, len(assign.Steps))
	for i, s := range assign.Steps {
		steps[i] = executor.Step{Name: s.displayName(), Run: s.Command}
	}
	return r.runSteps(ctx, r.runnerFor(checkout), steps, streamer), nil
}

func (r *Runner) awaitAssign(ctx context.Context) (assignPayload, error) {
	for {
		select {
		case push, ok := <-r.ch.Pushes():
			if !ok {
				return assignPayload{}, fmt.Errorf("connection closed before job:assign")
			}
			if push.Event != "job:assign" {
				// v0 expects only job:assign before started; ignore anything
				// else (job:cancel etc. are reserved for later slices).
				r.log.Warn("ignoring unexpected push before assign", "event", push.Event)
				continue
			}
			var p assignPayload
			if err := json.Unmarshal(push.Payload, &p); err != nil {
				return assignPayload{}, fmt.Errorf("decode job:assign: %w", err)
			}
			return p, nil
		case <-ctx.Done():
			return assignPayload{}, ctx.Err()
		}
	}
}

// redactURL strips any userinfo from a URL before it is logged, so embedded
// credentials (password, or a token riding in the username slot) never reach
// job logs. Returns the input unchanged if it does not parse as a URL.
func redactURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.User == nil {
		return raw
	}
	u.User = nil
	return u.String()
}

// urlWithUserinfo matches a scheme://userinfo@host... substring — the only URL
// shape that can carry an embedded credential. The userinfo (everything up to
// the @) is what we must scrub; the host/path that follows is harmless.
var urlWithUserinfo = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s@]+@[^\s]*`)

// redactErr scrubs credentials from an error string before it is logged. Git
// error messages routinely echo the remote URL, which on the clone path can
// embed a token in the userinfo slot (e.g. https://x-access-token:TOKEN@host).
// Any userinfo-bearing URL substring is rewritten through redactURL so the same
// credential-hygiene guarantee as redactURL covers free-form error text.
func redactErr(err error) string {
	if err == nil {
		return ""
	}
	return urlWithUserinfo.ReplaceAllStringFunc(err.Error(), redactURL)
}
