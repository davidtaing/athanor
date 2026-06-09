defmodule Athanor.Provisioner.Faulty do
  @moduledoc """
  Test-only Provisioner that injects a boot fault based on the booting Job's
  `image`, delegating every other call to `Athanor.Provisioner.Fake`. Two faults,
  each keyed on a sentinel image value:

    * `"fault:boot-raise"` — `boot/1` *raises* (a Provisioner crash / data-layer
      error that escapes as an exception).
    * `"fault:boot-error"` — `boot/1` returns `{:error, _}` (a fault surfaced as a
      value).

  The fault marker lives on the **Job row** the test created, not in global app
  config — so it is carried by the per-test, sandbox-isolated data and there is
  nothing to mutate or restore. That makes one globally-installed `Faulty` fully
  safe across `async: true` tests: a test's faulting Job can never trip a
  concurrent test's boot, and there is no shared mutable marker to race on. Any
  Job whose image isn't a `fault:` sentinel simply delegates to the Fake.
  Test-support only; not started in production.
  """
  @behaviour Athanor.Provisioner

  alias Athanor.Pipelines.Job
  alias Athanor.Provisioner.Fake

  @impl true
  def boot(runner) do
    case fault_for(runner) do
      :raise -> raise "boom: provisioner boot raised for job #{runner.job_id}"
      :error -> {:error, :boot_exploded}
      :none -> Fake.boot(runner)
    end
  end

  @impl true
  def destroy(runner), do: Fake.destroy(runner)

  defp fault_for(runner) do
    case Ash.get(Job, runner.job_id) do
      {:ok, %Job{image: "fault:boot-raise"}} -> :raise
      {:ok, %Job{image: "fault:boot-error"}} -> :error
      _ -> :none
    end
  end
end
