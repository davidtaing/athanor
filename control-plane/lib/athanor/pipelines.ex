defmodule Athanor.Pipelines do
  @moduledoc """
  The Pipelines domain: Pipelines and their Jobs.

  A Pipeline is the unit of work created by a single Trigger; it contains one or
  more Jobs and carries a derived rollup status. A Job is the schedulable unit of
  work and belongs to exactly one Pipeline. See `CONTEXT.md` for the canonical
  glossary.
  """
  use Ash.Domain, otp_app: :athanor, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Athanor.Pipelines.Pipeline do
      define :create_pipeline, action: :create
      define :get_pipeline, action: :read, get_by: [:id]
    end

    resource Athanor.Pipelines.Job do
      define :get_job, action: :read, get_by: [:id]
    end
  end
end
