package workspace

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// makeOriginRepo builds a local git repository on disk to act as the "remote"
// a Job clones from. It needs no network: the Clone under test uses the local
// path as the git URL. Returns the repo path and the names of the two refs it
// creates ("main" with marker-main, and a tag "v1" with marker-v1) so a test
// can assert Clone checks out the ref it asks for.
func makeOriginRepo(t *testing.T) (path, mainMarker, tagMarker string) {
	t.Helper()
	dir := t.TempDir()

	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
	}

	run("init", "-b", "main")
	if err := os.WriteFile(filepath.Join(dir, "marker"), []byte("main"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", ".")
	run("commit", "-m", "main commit")
	run("tag", "v1")

	return dir, "main", "v1"
}

func TestCloneChecksOutDeclaredRef(t *testing.T) {
	origin, mainRef, tagRef := makeOriginRepo(t)
	_ = tagRef

	dest := filepath.Join(t.TempDir(), "ws")

	res := Clone(context.Background(), Spec{URL: origin, Ref: mainRef, Dir: dest})
	if res.Err != nil {
		t.Fatalf("Clone err = %v, output:\n%s", res.Err, res.Output)
	}

	got, err := os.ReadFile(filepath.Join(dest, "marker"))
	if err != nil {
		t.Fatalf("reading checked-out file: %v", err)
	}
	if string(got) != "main" {
		t.Fatalf("marker = %q, want %q", got, "main")
	}
}

func TestCloneChecksOutTag(t *testing.T) {
	origin, _, tagRef := makeOriginRepo(t)
	dest := filepath.Join(t.TempDir(), "ws")

	res := Clone(context.Background(), Spec{URL: origin, Ref: tagRef, Dir: dest})
	if res.Err != nil {
		t.Fatalf("Clone err = %v, output:\n%s", res.Err, res.Output)
	}
	if _, err := os.Stat(filepath.Join(dest, "marker")); err != nil {
		t.Fatalf("expected checkout at tag %q: %v", tagRef, err)
	}
}

func TestCloneUnknownRefFailsWithOutput(t *testing.T) {
	origin, _, _ := makeOriginRepo(t)
	dest := filepath.Join(t.TempDir(), "ws")

	res := Clone(context.Background(), Spec{URL: origin, Ref: "no-such-ref", Dir: dest})
	if res.Err == nil {
		t.Fatal("Clone err = nil, want error for unknown ref")
	}
	if strings.TrimSpace(res.Output) == "" {
		t.Fatal("Clone output is empty, want captured git output explaining the failure")
	}
}

func TestCloneBadURLFailsWithOutput(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "ws")

	res := Clone(context.Background(), Spec{
		URL: filepath.Join(t.TempDir(), "does-not-exist"),
		Ref: "main",
		Dir: dest,
	})
	if res.Err == nil {
		t.Fatal("Clone err = nil, want error for a nonexistent repo")
	}
	if strings.TrimSpace(res.Output) == "" {
		t.Fatal("Clone output is empty, want captured git output explaining the failure")
	}
}
