defmodule Athanor.Pipelines do
  @moduledoc """
  The Pipelines domain: Pipelines and their Jobs.

  A Pipeline is the unit of work created by a single Trigger; it contains one or
  more Jobs and carries a derived rollup status. A Job is the schedulable unit of
  work and belongs to exactly one Pipeline. See `CONTEXT.md` for the canonical
  glossary.
  """
  use Ash.Domain, otp_app: :athanor, extensions: [AshAdmin.Domain]

  alias Athanor.Pipelines.DagAdvance

  admin do
    show? true
  end

  @doc """
  Advance the DAG after a Job reaches a terminal state (issue #9): enqueue
  newly-runnable dependents on success, skip transitive dependents on failure.
  Delegates to `Athanor.Pipelines.DagAdvance`; see its docs for the rules.
  """
  defdelegate advance(job), to: DagAdvance

  resources do
    resource Athanor.Pipelines.Pipeline do
      define :create_pipeline, action: :create
      define :get_pipeline, action: :read, get_by: [:id]
    end

    resource Athanor.Pipelines.Job do
      define :get_job, action: :read, get_by: [:id]
    end

    resource Athanor.Pipelines.Runner do
      define :get_runner, action: :read, get_by: [:id]
    end
  end
end
