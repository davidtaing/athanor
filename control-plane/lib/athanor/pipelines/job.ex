defmodule Athanor.Pipelines.Job do
  @moduledoc """
  A Job: the schedulable unit of work. One Runner executes exactly one Job.

  The Job lifecycle is an `AshStateMachine` over the glossary states. On Pipeline
  creation a dependency-free Job is `:queued`; a Job with Dependencies is
  `:waiting`. No execution happens in this slice, so Jobs simply sit in their
  initial state.

  Dependencies (the `needs` attribute) are the names of other Jobs in the same
  Pipeline that this Job depends on. They are validated for the whole Pipeline at
  creation time (see `Athanor.Pipelines.Pipeline`).
  """
  use Ash.Resource,
    otp_app: :athanor,
    domain: Athanor.Pipelines,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "jobs"
    repo Athanor.Repo
  end

  state_machine do
    initial_states [:waiting, :queued]
    default_initial_state :queued

    transitions do
      # No execution exists yet in this slice; transitions are declared so the
      # lifecycle is complete and future slices can drive them. They are not
      # exercised here.
      transition :assign, from: :queued, to: :assigned
      transition :start, from: :assigned, to: :running
      transition :succeed, from: :running, to: :succeeded
      transition :fail, from: [:assigned, :running], to: :failed
      transition :requeue, from: :assigned, to: :queued
      transition :skip, from: [:waiting, :queued], to: :skipped
      transition :enqueue, from: :waiting, to: :queued
      transition :cancel, from: [:waiting, :queued, :assigned, :running], to: :canceled
    end
  end

  actions do
    defaults [:read]

    # Jobs are created only as part of a Pipeline (see Pipeline.create). This
    # internal create is used by the Pipeline's nested manage_relationship; it
    # accepts the initial state computed by the Pipeline validation.
    create :create do
      primary? true
      accept [:name, :image, :steps, :env, :timeout, :needs, :state]
    end

    # Lifecycle transitions. No execution exists in this slice, so these are not
    # driven by any caller yet; they complete the state machine so future slices
    # (scheduling, dispatch, recovery, cancellation) can drive them.
    update :enqueue do
      change transition_state(:queued)
    end

    update :assign do
      change transition_state(:assigned)
    end

    update :start do
      change transition_state(:running)
    end

    update :succeed do
      change transition_state(:succeeded)
    end

    update :fail do
      # Failed always carries a Failure Reason (`CONTEXT.md`): the reason is
      # data on the single Failed state, never a distinct state. Canonical
      # tokens: nonzero_exit, timeout, runner_lost, boot_failure.
      argument :failure_reason, :atom,
        allow_nil?: false,
        constraints: [one_of: [:nonzero_exit, :timeout, :runner_lost, :boot_failure]]

      change set_attribute(:failure_reason, arg(:failure_reason))
      change transition_state(:failed)
    end

    update :requeue do
      change transition_state(:queued)
    end

    update :skip do
      change transition_state(:skipped)
    end

    update :cancel do
      change transition_state(:canceled)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false

    attribute :image, :string, allow_nil?: false

    # Ordered shell commands. Steps have no independent state (glossary).
    attribute :steps, {:array, :string}, allow_nil?: false, default: []

    # Plain environment variables made available to the Job's Steps.
    attribute :env, :map, allow_nil?: false, default: %{}

    # Per-Job timeout override in seconds; nil means "use the global default".
    attribute :timeout, :integer, allow_nil?: true

    # Names of Jobs in the same Pipeline this Job depends on (Dependencies).
    attribute :needs, {:array, :string}, allow_nil?: false, default: []

    # The Failure Reason on a Failed Job (`CONTEXT.md`). nil unless failed.
    attribute :failure_reason, :atom,
      allow_nil?: true,
      constraints: [one_of: [:nonzero_exit, :timeout, :runner_lost, :boot_failure]]

    timestamps()
  end

  relationships do
    belongs_to :pipeline, Athanor.Pipelines.Pipeline, allow_nil?: false
    has_one :runner, Athanor.Pipelines.Runner
  end

  identities do
    identity :unique_name_per_pipeline, [:pipeline_id, :name]
  end
end
