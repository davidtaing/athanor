defmodule Athanor.Pipelines.Pipeline do
  @moduledoc """
  A Pipeline: the unit of work created by a single Trigger. Contains one or more
  Jobs and carries a derived rollup status ("did this push pass?").

  Created with its full definition in one action (PRD user story 1): a git URL +
  ref and a list of named Jobs with ordered Steps, a container image, and
  optional Dependencies, env vars, and timeout override. The definition is
  validated before any Job is written (cycles, dangling Dependencies, empty
  Jobs, missing image all rejected). No execution happens in this slice.
  """
  use Ash.Resource,
    otp_app: :athanor,
    domain: Athanor.Pipelines,
    data_layer: AshPostgres.DataLayer

  alias Athanor.Pipelines.Pipeline.Calculations.RollupStatus
  alias Athanor.Pipelines.Pipeline.Changes.BuildJobs
  alias Athanor.Pipelines.Pipeline.Validations.ValidateDefinition

  postgres do
    table "pipelines"
    repo Athanor.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:git_url, :git_ref]

      # The full Job definition for the Pipeline. Each entry is a map with
      # :name, :image, :steps, optional :env, :timeout, and :needs.
      argument :jobs, {:array, :map}, allow_nil?: false

      validate ValidateDefinition
      change BuildJobs
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :git_url, :string, allow_nil?: false

    attribute :git_ref, :string, allow_nil?: false

    timestamps()
  end

  relationships do
    has_many :jobs, Athanor.Pipelines.Job
  end

  calculations do
    # Derived from Job states, never stored (ADR 0002).
    calculate :status, :atom, RollupStatus do
      load jobs: [:state]
    end
  end
end
