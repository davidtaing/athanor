defmodule Athanor.Provisioner.Erroring do
  @moduledoc """
  Test-only Provisioner that returns `{:error, _}` (rather than raising) from
  `boot/1` for the Runner whose `job_id` matches the configured marker,
  delegating every other call to `Athanor.Provisioner.Fake`.

  Exercises the synchronous-boot-error path (issue #10 acceptance criterion 5):
  a `boot` that fails fast must drive the same bounded requeue/`boot_failure`
  recovery the deadline sweep would, reaping any container, rather than leaving
  the Job to time out. Wired in per-test via the `:athanor, :provisioner` config
  seam `Athanor.Provisioner.impl/0` reads, then reset in `on_exit`. The marker is
  a Job *id* (a globally unique UUID) so the global config swap can never make a
  concurrent async test's own boot error — a non-matching id delegates to Fake.
  Test-support only; not started in production.
  """
  @behaviour Athanor.Provisioner

  alias Athanor.Provisioner.Fake

  @doc "The Job id whose boot should error, read from config."
  def error_on, do: Application.get_env(:athanor, :erroring_provisioner_job_id)

  @impl true
  def boot(runner) do
    if runner.job_id == error_on() do
      {:error, :boot_exploded}
    else
      Fake.boot(runner)
    end
  end

  @impl true
  def destroy(runner), do: Fake.destroy(runner)
end
