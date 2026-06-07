package main

import "testing"

func TestConfigFromEnvReadsAllFields(t *testing.T) {
	env := map[string]string{
		"ATHANOR_CONTROL_PLANE_URL": "ws://cp.example/runner/websocket",
		"ATHANOR_RUNNER_ID":         "runner-42",
		"ATHANOR_BOOT_TOKEN":        "boot-secret",
	}
	get := func(k string) string { return env[k] }

	cfg, err := configFromEnv(get)
	if err != nil {
		t.Fatalf("configFromEnv: %v", err)
	}
	if cfg.URL != env["ATHANOR_CONTROL_PLANE_URL"] {
		t.Errorf("URL = %q", cfg.URL)
	}
	if cfg.RunnerID != "runner-42" {
		t.Errorf("RunnerID = %q", cfg.RunnerID)
	}
	if cfg.BootToken != "boot-secret" {
		t.Errorf("BootToken = %q", cfg.BootToken)
	}
}

func TestConfigFromEnvMissingFieldIsError(t *testing.T) {
	env := map[string]string{
		"ATHANOR_CONTROL_PLANE_URL": "ws://cp/runner/websocket",
		// RUNNER_ID and BOOT_TOKEN missing
	}
	get := func(k string) string { return env[k] }

	if _, err := configFromEnv(get); err == nil {
		t.Fatal("configFromEnv err = nil, want error for missing required env")
	}
}
