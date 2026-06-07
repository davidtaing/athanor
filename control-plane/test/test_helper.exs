# Docker-backed tests boot real containers against the local daemon, so they are
# excluded from the default fast suite (and from CI, which has no daemon). Run
# them explicitly: `mix test --include docker` / `--include e2e`.
ExUnit.start(exclude: [:docker, :e2e])
Ecto.Adapters.SQL.Sandbox.mode(Athanor.Repo, :manual)

# Create the Provisioner.Recorder registry table here so it is owned by the
# long-lived test-runner process. If a transient test process created it, the
# table would be destroyed when that process exited mid-suite, wiping every
# concurrent test's recorder registration (a timing-sensitive race under async).
Athanor.Provisioner.Recorder.ensure_table()
