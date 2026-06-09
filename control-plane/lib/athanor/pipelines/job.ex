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

    # The Failure Reason is data on the single Failed state (`CONTEXT.md`); the
    # DB only ever stores NULL or one of the four canonical tokens, regardless
    # of which writer touches the row.
    check_constraints do
      check_constraint :failure_reason,
        name: "jobs_failure_reason_check",
        check:
          "failure_reason IS NULL OR failure_reason IN ('nonzero_exit', 'timeout', 'runner_lost', 'boot_failure')"
    end
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
    defaults [:read, :update]

    # Jobs are created only as part of a Pipeline (see Pipeline.create). This
    # internal create is used by the Pipeline's nested manage_relationship; it
    # accepts the initial state computed by the Pipeline validation.
    create :create do
      primary? true
      accept [:name, :image, :steps, :env, :timeout, :needs, :state]

      # A Job created already `:queued` (no Dependencies) stamps its place in the
      # queue: `WHERE state = 'queued' ORDER BY queued_at` IS the queue
      # (docs/supervision-tree.md). A `:waiting` Job gets stamped later, on enqueue.
      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :state) == :queued do
          Ash.Changeset.force_change_attribute(changeset, :queued_at, DateTime.utc_now())
        else
          changeset
        end
      end
    end

    # Record that the Runner acknowledged delivery of its job:assign (PRD #35).
    # The stamp is the fact future rejoin logic reads (assigned + unstamped ⇒
    # re-send job:assign); this action only records it. Idempotent: a duplicate
    # job:ack keeps the first stamp (ack-and-ignore, protocol invariant 2). No
    # state transition — acknowledgement is a fact on the Job, not a lifecycle
    # state. COALESCE makes first-stamp-wins atomic DB-side, so concurrent
    # duplicate acks (e.g. a rejoin re-send racing the original) cannot
    # overwrite the first timestamp.
    update :acknowledge do
      change atomic_update(
               :acknowledged_at,
               expr(fragment("COALESCE(?, ?)", acknowledged_at, now()))
             )
    end

    # Lifecycle transitions. No execution exists in this slice, so these are not
    # driven by any caller yet; they complete the state machine so future slices
    # (scheduling, dispatch, recovery, cancellation) can drive them.
    update :enqueue do
      # Stamp the queue position as the Job becomes runnable (its Dependencies
      # have all succeeded). queued_at orders the queue head for dispatch.
      change set_attribute(:queued_at, &DateTime.utc_now/0)
      change transition_state(:queued)
    end

    update :assign do
      # The deadline default is computed from config in an anonymous change, which
      # cannot run atomically — and dispatch already wraps this in an explicit
      # transaction, so atomic single-statement execution buys nothing here.
      require_atomic? false

      # The boot deadline is stamped here, in the dispatch intent transaction,
      # *before* any container is booted (issue #10, record-before-act). A crash
      # anywhere in boot then leaves an `:assigned` row carrying a live deadline
      # the sweep enforces — deadlines are columns, not in-memory timers. Every
      # `:assigned` Job carries one, so the caller may supply an explicit instant
      # (the dispatch transaction does) or fall back to `now + boot_timeout`.
      argument :boot_deadline_at, :utc_datetime_usec, allow_nil?: true

      change fn changeset, _context ->
        deadline =
          Ash.Changeset.get_argument(changeset, :boot_deadline_at) ||
            DateTime.add(
              DateTime.utc_now(),
              Application.fetch_env!(:athanor, :boot_timeout),
              :millisecond
            )

        Ash.Changeset.force_change_attribute(changeset, :boot_deadline_at, deadline)
      end

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
      # A terminal Job holds no live boot deadline — clear it so the sweep's
      # `:assigned AND boot_deadline_at < now()` query can never re-touch a
      # failed row (issue #10).
      change set_attribute(:boot_deadline_at, nil)
      change transition_state(:failed)
    end

    update :requeue do
      # Boot timed out / boot failed (issue #10): count the attempt and clear the
      # now-stale boot deadline as the Job returns to the queue. `queued_at` is
      # deliberately *not* re-stamped — the boot-attempts ceiling bounds
      # starvation, so the Job keeps its place at the queue head.
      change increment(:boot_attempts)
      change set_attribute(:boot_deadline_at, nil)
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

    # Ordered Steps: each is an object `%{"command" => string, "name" => string?}`
    # (PRD #35). The `command` is the shell command; `name` is an optional display
    # name (display falls back to `command`). Steps have no independent state
    # (glossary). The Definition is validated before any Job is written, so by the
    # time a Step reaches storage it is already a well-formed object.
    attribute :steps, {:array, :map}, allow_nil?: false, default: []

    # Plain environment variables made available to the Job's Steps.
    attribute :env, :map, allow_nil?: false, default: %{}

    # Per-Job timeout override in seconds; nil means "use the global default".
    attribute :timeout, :integer, allow_nil?: true

    # Names of Jobs in the same Pipeline this Job depends on (Dependencies).
    attribute :needs, {:array, :string}, allow_nil?: false, default: []

    # When the Runner acknowledged delivery of its job:assign (job:ack, PRD #35).
    # nil until acknowledged; the rejoin re-send rule reads it (assigned +
    # unstamped ⇒ re-send job:assign). A fact, never a lifecycle state.
    attribute :acknowledged_at, :utc_datetime_usec, allow_nil?: true

    # When the Job entered the `queued` state. The queue has no data structure;
    # `WHERE state = 'queued' ORDER BY queued_at` IS the queue
    # (docs/supervision-tree.md), so dispatch takes the oldest-queued first.
    attribute :queued_at, :utc_datetime_usec, allow_nil?: true

    # Boot deadline for an `:assigned` Job (issue #10, boot-failure slice). Stamped
    # in the dispatch intent transaction *before* any container is booted, so a
    # crash/hang anywhere in boot leaves a row the sweep can enforce: deadlines are
    # columns, not in-memory timers (docs/supervision-tree.md, ADR 0002). The sweep
    # finds `:assigned` Jobs past this and drives `:requeue`/`:fail`. nil unless
    # assigned-and-not-yet-joined; cleared back to nil when the Job leaves boot.
    attribute :boot_deadline_at, :utc_datetime_usec, allow_nil?: true

    # How many times this Job has been dispatched and timed out / failed to boot
    # (issue #10). The boot-attempts ceiling (3) bounds starvation: a poison Job
    # retries at most 3× then fails terminally with `boot_failure`, so a requeue
    # can safely keep `queued_at` (no re-stamp) without starving the rest forever.
    attribute :boot_attempts, :integer, allow_nil?: false, default: 0

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
