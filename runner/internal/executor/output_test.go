package executor

import (
	"bytes"
	"context"
	"testing"
)

// TestShellRunnerWritesStepOutputToProvidedWriter: when an output writer is set,
// the Step's stdout and stderr are merged into it (in pipe-arrival order,
// untagged) — that single merged stream is what the log streamer batches into
// log:chunk (PRD: one merged stream, stdout and stderr interleaved).
func TestShellRunnerWritesStepOutputToProvidedWriter(t *testing.T) {
	var buf bytes.Buffer
	r := NewShellRunner()
	r.Output = &buf

	code, err := r.RunStep(context.Background(), Step{
		Name: "echo",
		Run:  "echo out; echo err 1>&2",
	})
	if err != nil {
		t.Fatalf("RunStep: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}

	got := buf.String()
	if !bytes.Contains(buf.Bytes(), []byte("out")) || !bytes.Contains(buf.Bytes(), []byte("err")) {
		t.Fatalf("merged output = %q, want both stdout and stderr captured", got)
	}
}
