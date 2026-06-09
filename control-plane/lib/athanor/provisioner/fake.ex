defmodule Athanor.Provisioner.Fake do
  @moduledoc """
  Test Provisioner (MVP PRD testing seam 3). The Runner record + Boot Token are
  written by the dispatch intent transaction *before* boot (issue #10), so the
  fake receives an already-created Runner and boots no container — it just records
  the call so a test can assert call counts and read the surfaced Boot Token. The
  recorded `runner` carries the same plaintext Boot Token the real driver would
  inject into the container.

  Calls are recorded into a per-test `Athanor.Provisioner.Recorder` Agent,
  located through the `$callers` chain so recording works even when the call
  originates inside a Channel process spawned by the test.
  """
  @behaviour Athanor.Provisioner

  alias Athanor.Provisioner.Recorder

  @impl true
  def boot(runner) do
    Recorder.record(:boot, runner: runner, job_id: runner.job_id)
    {:ok, runner}
  end

  @impl true
  def destroy(runner) do
    Recorder.record(:destroy, runner: runner)
    :ok
  end
end
