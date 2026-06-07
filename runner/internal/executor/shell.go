package executor

import (
	"context"
	"errors"
	"os"
	"os/exec"
)

// ShellRunner runs a Step's command through a shell, inheriting the runner's
// stdout/stderr. It is the production StepRunner; tests inject a StubRunner.
//
// A Step that runs and exits nonzero returns that exit code with a nil error —
// the nonzero exit is a fact the control plane derives a verdict from, not a
// runner failure. A non-nil error means the command could not be launched at
// all.
type ShellRunner struct {
	// Shell is the shell binary used to interpret a Step's Run command.
	Shell string
	// Dir is the working directory Steps run from — the cloned workspace
	// (issue #7). Empty means the process's current directory (the runner's
	// default), used by tests that don't need a checkout.
	Dir string
}

// NewShellRunner returns a ShellRunner using /bin/sh.
func NewShellRunner() *ShellRunner {
	return &ShellRunner{Shell: "/bin/sh"}
}

// RunStep implements StepRunner.
func (r *ShellRunner) RunStep(ctx context.Context, step Step) (int, error) {
	cmd := exec.CommandContext(ctx, r.Shell, "-c", step.Run)
	cmd.Dir = r.Dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err == nil {
		return 0, nil
	}

	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		// The Step ran and exited nonzero: a fact, not a runner error.
		return exitErr.ExitCode(), nil
	}

	// The command could not be launched at all.
	return 0, err
}
