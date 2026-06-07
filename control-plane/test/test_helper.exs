ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Athanor.Repo, :manual)

# Create the Provisioner.Recorder registry table here so it is owned by the
# long-lived test-runner process. If a transient test process created it, the
# table would be destroyed when that process exited mid-suite, wiping every
# concurrent test's recorder registration (a timing-sensitive race under async).
Athanor.Provisioner.Recorder.ensure_table()
