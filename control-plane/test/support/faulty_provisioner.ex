defmodule Athanor.Provisioner.Faulty do
  @moduledoc """
  Test-only Provisioner that injects a boot fault for the Job whose id matches a
  configured marker, delegating every other call to `Athanor.Provisioner.Fake`.
  Two independent faults, each keyed on its own marker:

    * `:faulty_provisioner_raise_job_id` — `boot/1` *raises* (a Provisioner crash
      / data-layer error that escapes as an exception).
    * `:faulty_provisioner_error_job_id` — `boot/1` returns `{:error, _}` (a fault
      surfaced as a value).

  One provisioner reading *both* markers — rather than two provisioners each
  shadowing the other — is what makes the `:athanor, :provisioner` config swap
  safe across `async: true` tests: whichever test installs `Faulty`, every test's
  own marker is still honored, and a non-matching Job id simply delegates to the
  Fake. The markers are Job *ids* (globally unique UUIDs) so a swap can never make
  a concurrent test's own boot fault. Test-support only; not started in production.
  """
  @behaviour Athanor.Provisioner

  alias Athanor.Provisioner.Fake

  @doc "The Job id whose boot should raise, read from config."
  def raise_on, do: Application.get_env(:athanor, :faulty_provisioner_raise_job_id)

  @doc "The Job id whose boot should return `{:error, _}`, read from config."
  def error_on, do: Application.get_env(:athanor, :faulty_provisioner_error_job_id)

  @impl true
  def boot(runner) do
    cond do
      runner.job_id == raise_on() ->
        raise "boom: provisioner boot raised for job #{runner.job_id}"

      runner.job_id == error_on() ->
        {:error, :boot_exploded}

      true ->
        Fake.boot(runner)
    end
  end

  @impl true
  def destroy(runner), do: Fake.destroy(runner)
end
