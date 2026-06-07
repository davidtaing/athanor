// Package workspace prepares the directory a Job's Steps run from: it clones the
// Pipeline's declared git URL at the declared ref into a workspace directory
// before any Step runs.
//
// Public repositories only — credential delivery is out of scope for the MVP
// (docs/prd/athanor-mvp.md). A failed clone (bad URL, unknown ref, network
// error) is reported as an error with the git output captured, so the runner
// can fail the Job cleanly with useful output, exactly like a failing Step
// (issue #7).
package workspace

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
)

// Spec describes the checkout a Job needs: the git URL, the ref to check out,
// and the destination directory the clone is materialised into.
type Spec struct {
	URL string
	Ref string
	Dir string
}

// Result is the outcome of a Clone. Output is git's combined stdout+stderr,
// captured so a failed clone surfaces useful diagnostics in the Job's log the
// same way a failing Step's output does. Err is non-nil when the clone failed.
type Result struct {
	Output string
	Err    error
}

// Clone checks out spec.URL at spec.Ref into spec.Dir. It is a shallow,
// single-branch clone (--depth 1): a CI checkout needs the tree at one ref, not
// the history. --branch accepts a branch name or a tag.
//
// Clone never authenticates: the MVP is public repositories only. A clone
// failure (bad URL, unknown ref, network error) returns a Result whose Err is
// non-nil and whose Output carries git's explanation.
//
// Clone safety model: the URL and ref are control-plane-supplied, not arbitrary
// runner input, but treat them as untrusted anyway. The "--" terminator
// neutralizes a flag-shaped URL or ref (e.g. a value starting with "-") so it
// can never be reinterpreted as a git option. Public-repo safety also leans on
// git's default protocol.allow=user, which blocks the dangerous transports
// (ext::, file://) that could run commands or read the host filesystem; only
// the network transports (https://, git://) are permitted.
func Clone(ctx context.Context, spec Spec) Result {
	cmd := exec.CommandContext(ctx, "git", "clone",
		"--depth", "1",
		"--branch", spec.Ref,
		"--",
		spec.URL,
		spec.Dir,
	)

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	err := cmd.Run()
	if err != nil {
		return Result{
			Output: buf.String(),
			Err:    fmt.Errorf("git clone %s@%s: %w", spec.URL, spec.Ref, err),
		}
	}
	return Result{Output: buf.String()}
}
