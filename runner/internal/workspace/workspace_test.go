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
// path as the git URL.
//
// The branch and tag deliberately DIVERGE so a checkout test can prove real ref
// selection rather than coincidentally landing on shared content: the repo is
// committed with marker "v1", tagged "v1" at that commit, then a second commit
// advances the "main" branch to marker "main". The returned tagMarker ("v1") is
// the pre-divergence content the tag still points at; mainMarker ("main") is the
// later, branch-only content. Checking out the tag must see "v1" and NOT "main".
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

	writeMarker := func(content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "marker"), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	run("init", "-b", "main")

	// First commit: tag "v1" pins this pre-divergence content.
	writeMarker("v1")
	run("add", ".")
	run("commit", "-m", "tagged commit")
	run("tag", "v1")

	// Second commit advances "main" past the tag, so branch and tag now differ.
	writeMarker("main")
	run("add", ".")
	run("commit", "-m", "main commit after tag")

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
	origin, mainMarker, tagRef := makeOriginRepo(t)
	dest := filepath.Join(t.TempDir(), "ws")

	res := Clone(context.Background(), Spec{URL: origin, Ref: tagRef, Dir: dest})
	if res.Err != nil {
		t.Fatalf("Clone err = %v, output:\n%s", res.Err, res.Output)
	}

	// The tag points at the pre-divergence commit, which the "main" branch has
	// since advanced past. Seeing the tag's content ("v1") and NOT the later
	// branch content ("main") proves Clone selected the requested ref rather
	// than landing on whatever HEAD happens to be.
	got, err := os.ReadFile(filepath.Join(dest, "marker"))
	if err != nil {
		t.Fatalf("reading checked-out file at tag %q: %v", tagRef, err)
	}
	if string(got) == mainMarker {
		t.Fatalf("marker = %q, which is the later branch content; tag checkout did not select the tagged ref", got)
	}
	if string(got) != "v1" {
		t.Fatalf("marker = %q, want %q (the tagged pre-divergence content)", got, "v1")
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
