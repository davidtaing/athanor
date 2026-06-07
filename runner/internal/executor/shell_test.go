package executor

import (
	"context"
	"os"
	"path/filepath"
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

func TestShellRunnerRunsInConfiguredDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "in-workspace"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	r := NewShellRunner()
	r.Dir = dir

	// The Step fails unless it runs with dir as its working directory: the file
	// only exists there. This pins "Steps run with the workspace as working
	// directory" (issue #7) to observable behavior, not to inspecting cmd.Dir.
	code, err := r.RunStep(context.Background(), Step{Name: "ls", Run: "test -f in-workspace"})
	if err != nil {
		t.Fatalf("RunStep err = %v, want nil", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0 — Step did not run in the configured Dir", code)
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
