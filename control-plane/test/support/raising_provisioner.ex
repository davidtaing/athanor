defmodule Athanor.Provisioner.Raising do
  @moduledoc """
  Test-only Provisioner that *raises* (rather than returning `{:error, _}`) when
  booting the Job whose id matches the configured marker, delegating every other
  call to `Athanor.Provisioner.Fake`.

  Exercises the Scheduler's guarantee that a raised boot for one Job never aborts
  the dispatch pass for the rest of the queue. Wired in per-test via the same
  `:athanor, :provisioner` config seam `Athanor.Provisioner.impl/0` reads, then
  reset in the test's `on_exit`. The marker is a Job *id* (a globally unique
  UUID) rather than a name so the global config swap can never make a concurrent
  async test's own boot raise — a non-matching id just delegates to the Fake.
  Test-support only; not started in production.
  """
  @behaviour Athanor.Provisioner

  alias Athanor.Provisioner.Fake

  @doc "The Job id whose boot should raise, read from config."
  def raise_on, do: Application.get_env(:athanor, :raising_provisioner_job_id)

  @impl true
  def boot(job) do
    if job.id == raise_on() do
      raise "boom: provisioner boot raised for job #{job.id}"
    else
      Fake.boot(job)
    end
  end

  @impl true
  def destroy(runner), do: Fake.destroy(runner)
end
