// Command athanor-runner is the ephemeral Go runner: one process executes
// exactly one Job, then exits (ADR 0003). It reads the control-plane URL and
// Boot Token from the environment, joins over a Phoenix Channels WebSocket,
// runs the Job's Steps, reports the outcome, and exits with the Job's exit
// code. The runner never loops.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/davidtaing/athanor/runner/internal/executor"
	"github.com/davidtaing/athanor/runner/internal/runner"
)

const (
	envURL       = "ATHANOR_CONTROL_PLANE_URL"
	envRunnerID  = "ATHANOR_RUNNER_ID"
	envBootToken = "ATHANOR_BOOT_TOKEN"
)

// configFromEnv builds the runner config from environment lookups. get is
// os.Getenv in production; tests inject a map lookup.
func configFromEnv(get func(string) string) (runner.Config, error) {
	cfg := runner.Config{
		URL:       get(envURL),
		RunnerID:  get(envRunnerID),
		BootToken: get(envBootToken),
	}
	missing := []string{}
	if cfg.URL == "" {
		missing = append(missing, envURL)
	}
	if cfg.RunnerID == "" {
		missing = append(missing, envRunnerID)
	}
	if cfg.BootToken == "" {
		missing = append(missing, envBootToken)
	}
	if len(missing) > 0 {
		return runner.Config{}, fmt.Errorf("missing required environment: %v", missing)
	}
	return cfg, nil
}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	slog.SetDefault(log)

	cfg, err := configFromEnv(os.Getenv)
	if err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}

	r := runner.New(cfg, executor.NewShellRunner())
	code, err := r.Run(context.Background())
	if err != nil {
		log.Error("run failed", "err", err)
	}
	os.Exit(code)
}
