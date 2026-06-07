package main

import "testing"

func TestStartupLine(t *testing.T) {
	got := startupLine()
	want := "athanor-runner starting"
	if got != want {
		t.Errorf("startupLine() = %q, want %q", got, want)
	}
}
