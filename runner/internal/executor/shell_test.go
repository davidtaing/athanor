package executor

import (
	"context"
	"testing"
)

func TestShellRunnerExitZero(t *testing.T) {
	r := NewShellRunner()
	code, err := r.RunStep(context.Background(), Step{Name: "ok", Run: "exit 0"})
	if err != nil {
		t.Fatalf("RunStep returned err = %v, want nil", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
}

func TestShellRunnerNonzeroIsNotError(t *testing.T) {
	r := NewShellRunner()
	// A Step that runs and exits nonzero is a fact, not a runner error.
	code, err := r.RunStep(context.Background(), Step{Name: "fail", Run: "exit 3"})
	if err != nil {
		t.Fatalf("RunStep returned err = %v, want nil (nonzero exit is data, not error)", err)
	}
	if code != 3 {
		t.Fatalf("exit code = %d, want 3", code)
	}
}

func TestShellRunnerLaunchFailureIsError(t *testing.T) {
	r := NewShellRunner()
	r.Shell = "/no/such/shell/binary"
	_, err := r.RunStep(context.Background(), Step{Name: "x", Run: "true"})
	if err == nil {
		t.Fatal("RunStep err = nil, want non-nil for a command that cannot launch")
	}
}
