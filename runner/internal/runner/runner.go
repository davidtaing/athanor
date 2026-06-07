// Package runner orchestrates one Job for one process lifetime: join the
// control plane with the Boot Token, receive the job:assign push, report
// job:started, run the Job's Steps through the executor, report job:finished
// with the exit status, then return so the process can exit. One Job per
// process — the runner never loops (ADR 0003, issue #5).
package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/davidtaing/athanor/runner/internal/executor"
	"github.com/davidtaing/athanor/runner/internal/protocol"
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

// Runner wires the protocol client to the executor for a single Job.
type Runner struct {
	cfg  Config
	exec executor.StepRunner
	ch   channel
	log  *slog.Logger
}

// assignPayload is the job:assign payload (docs/prd/runner-protocol.md). steps
// is an ordered list of command strings (the Job.steps array attribute); no
// image (the Runner is already inside it) and no timeout (control-plane
// enforced).
type assignPayload struct {
	JobID  string            `json:"job_id"`
	GitURL string            `json:"git_url"`
	GitRef string            `json:"git_ref"`
	Steps  []string          `json:"steps"`
	Env    map[string]string `json:"env"`
}

// finishedPayload is the job:finished payload — facts only, no verdict. The
// control plane derives the verdict (exit 0 ⇒ succeeded; nonzero ⇒ failed,
// reason nonzero_exit).
type finishedPayload struct {
	ExitCode        int  `json:"exit_code"`
	FailedStepIndex *int `json:"failed_step_index,omitempty"`
}

// New returns a Runner that dials the configured URL.
func New(cfg Config, exec executor.StepRunner) *Runner {
	return &Runner{
		cfg:  cfg,
		exec: exec,
		ch:   protocol.NewClient(cfg.URL, cfg.RunnerID),
		log:  slog.Default(),
	}
}

// Run executes the full single-Job lifecycle and returns the Job's exit code.
// The returned error is reserved for protocol/transport failures (a failing
// Step is reported via the exit code, not an error). The caller exits the
// process with the returned code.
func (r *Runner) Run(ctx context.Context) (int, error) {
	defer func() { _ = r.ch.Close() }()

	joined, err := r.ch.JoinWithBootToken(ctx, r.cfg.BootToken)
	if err != nil {
		// A definitively rejected join fails fast — exit nonzero immediately
		// rather than retrying (PRD: rejected join).
		return 1, fmt.Errorf("join: %w", err)
	}
	r.log.Info("joined control plane",
		"protocol_version", joined.ProtocolVersion, "verdict", joined.Verdict)

	if joined.Verdict == "stop" {
		// The Job went terminal while we were away — nothing to run.
		return 0, nil
	}

	assign, err := r.awaitAssign(ctx)
	if err != nil {
		return 1, err
	}
	r.log.Info("job assigned", "job_id", assign.JobID, "steps", len(assign.Steps))

	if err := r.ch.Send(ctx, "job:started", map[string]any{}); err != nil {
		return 1, fmt.Errorf("job:started: %w", err)
	}

	steps := make([]executor.Step, len(assign.Steps))
	for i, cmd := range assign.Steps {
		steps[i] = executor.Step{Name: fmt.Sprintf("step-%d", i), Run: cmd}
	}
	result := executor.RunSteps(ctx, r.exec, steps)

	finished := finishedPayload{
		ExitCode:        result.ExitCode,
		FailedStepIndex: result.FailedStepIndex,
	}
	if err := r.ch.Send(ctx, "job:finished", finished); err != nil {
		return 1, fmt.Errorf("job:finished: %w", err)
	}

	return result.ExitCode, nil
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
