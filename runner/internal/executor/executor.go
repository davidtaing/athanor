// Package executor runs a Job's Steps sequentially.
//
// A Step is an ordered command inside a Job (CONTEXT.md). It is not a
// scheduled entity and has no independent state; the executor runs Steps in
// order and stops at the first nonzero exit, reporting that exit code as the
// Job's outcome. The control plane derives the Job verdict from the exit code
// (exit 0 ⇒ succeeded; nonzero ⇒ failed, reason nonzero_exit) — the runner
// reports facts only (docs/prd/runner-protocol.md).
package executor

import "context"

// Step is an ordered command inside a Job.
type Step struct {
	Name string
	Run  string
}

// Result is the outcome of running a Job's Steps.
type Result struct {
	// ExitCode is the exit code of the last Step run: 0 if every Step
	// succeeded, otherwise the nonzero code of the first failing Step.
	ExitCode int
	// FailedStepIndex is the index of the Step that exited nonzero, or nil
	// when every Step succeeded.
	FailedStepIndex *int
}

// StepRunner executes a single Step and returns its exit code. A non-nil error
// reports a failure to run the Step at all (e.g. the command could not be
// launched), distinct from the Step running and exiting nonzero.
type StepRunner interface {
	RunStep(ctx context.Context, step Step) (exitCode int, err error)
}

// StubRunner adapts a function to the StepRunner interface, for tests.
type StubRunner func(ctx context.Context, step Step) (int, error)

// RunStep implements StepRunner.
func (f StubRunner) RunStep(ctx context.Context, step Step) (int, error) {
	return f(ctx, step)
}

// RunSteps runs steps in order through runner, stopping at the first Step that
// exits nonzero (or fails to run). The remaining Steps are not run.
func RunSteps(ctx context.Context, runner StepRunner, steps []Step) Result {
	for i, step := range steps {
		exitCode, err := runner.RunStep(ctx, step)
		if err != nil {
			idx := i
			return Result{ExitCode: 1, FailedStepIndex: &idx}
		}
		if exitCode != 0 {
			idx := i
			return Result{ExitCode: exitCode, FailedStepIndex: &idx}
		}
	}
	return Result{ExitCode: 0}
}
