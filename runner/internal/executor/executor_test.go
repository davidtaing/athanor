package executor

import (
	"context"
	"testing"
)

func TestRunStepsAllSucceed(t *testing.T) {
	var ran []string
	step := func(name string) Step {
		return Step{Name: name, Run: "echo " + name}
	}
	stub := StubRunner(func(_ context.Context, s Step) (int, error) {
		ran = append(ran, s.Name)
		return 0, nil
	})

	result := RunSteps(context.Background(), stub, []Step{step("a"), step("b"), step("c")})

	if result.ExitCode != 0 {
		t.Fatalf("ExitCode = %d, want 0", result.ExitCode)
	}
	if result.FailedStepIndex != nil {
		t.Fatalf("FailedStepIndex = %v, want nil", result.FailedStepIndex)
	}
	if got, want := len(ran), 3; got != want {
		t.Fatalf("ran %d steps (%v), want %d", got, ran, want)
	}
}

func TestRunStepsStopsAtFirstNonzero(t *testing.T) {
	var ran []string
	stub := StubRunner(func(_ context.Context, s Step) (int, error) {
		ran = append(ran, s.Name)
		if s.Name == "b" {
			return 7, nil
		}
		return 0, nil
	})

	steps := []Step{{Name: "a"}, {Name: "b"}, {Name: "c"}}
	result := RunSteps(context.Background(), stub, steps)

	if result.ExitCode != 7 {
		t.Fatalf("ExitCode = %d, want 7", result.ExitCode)
	}
	if result.FailedStepIndex == nil || *result.FailedStepIndex != 1 {
		t.Fatalf("FailedStepIndex = %v, want 1", result.FailedStepIndex)
	}
	if got, want := len(ran), 2; got != want {
		t.Fatalf("ran %d steps (%v), want %d — should stop after the failing Step", got, ran, want)
	}
}
