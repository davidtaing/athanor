defmodule Athanor.Provisioner do
  @moduledoc """
  The Provisioner: boots a Runner when a Job needs one and destroys it when the
  Job ends (`CONTEXT.md`, ADR 0003). Defined as a behaviour so the control
  plane depends on the contract, not the Docker implementation — the production
  driver talks to the Docker Engine API; tests use a fake that records calls
  and surfaces tokens (MVP PRD testing seam 3).

  Per ADR 0003 the Runner record and its one-time Boot Token are created *before*
  the container boots. Issue #10's record-before-act flip moves that record write
  into the Scheduler's dispatch *intent transaction* (Runner row + Boot Token +
  `boot_deadline_at` + Job `:assign`, atomically) — so by the time `boot/1` runs
  the Runner already exists, and `boot/1` performs only the irreversible external
  action: create + start the container, then stamp its `container_id`. The Runner
  carries its plaintext Boot Token for injection.
  """

  alias Athanor.Pipelines.Runner

  @doc """
  Boot a container for an already-created Runner (the dispatch intent transaction
  wrote the Runner row first, issue #10). Creates + starts the container with the
  Runner's Boot Token injected, stamps `container_id`, and returns the Runner.
  """
  @callback boot(Runner.t()) :: {:ok, Runner.t()} | {:error, term()}

  @doc """
  Destroy the Runner (force-destroy the container).
  """
  @callback destroy(Runner.t()) :: :ok | {:error, term()}

  @doc """
  The configured Provisioner implementation. Defaults to the fake; the Docker
  implementation is wired in via config when it exists.
  """
  def impl do
    Application.get_env(:athanor, :provisioner, Athanor.Provisioner.Fake)
  end

  def boot(%Runner{} = runner), do: impl().boot(runner)
  def destroy(%Runner{} = runner), do: impl().destroy(runner)
end
