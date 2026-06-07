defmodule Athanor.Provisioner do
  @moduledoc """
  The Provisioner: boots a Runner when a Job needs one and destroys it when the
  Job ends (`CONTEXT.md`, ADR 0003). Defined as a behaviour so the control
  plane depends on the contract, not the Docker implementation — the production
  driver talks to the Docker Engine API; tests use a fake that records calls
  and surfaces tokens (MVP PRD testing seam 3).

  Per ADR 0003 the Provisioner creates the Runner record and its one-time Boot
  Token *before* booting the container, then boots. Here `boot/1` returns the
  created Runner (carrying its plaintext Boot Token) so the booting layer can
  inject the token into the container.
  """

  alias Athanor.Pipelines.Job
  alias Athanor.Pipelines.Runner

  @doc """
  Boot a Runner for the given Job: create its Runner record + Boot Token, then
  boot the container. Returns the created Runner.
  """
  @callback boot(Job.t()) :: {:ok, Runner.t()} | {:error, term()}

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

  def boot(%Job{} = job), do: impl().boot(job)
  def destroy(%Runner{} = runner), do: impl().destroy(runner)
end
