defmodule Athanor.Pipelines.Runner do
  @moduledoc """
  A Runner: the ephemeral, isolated environment booted to execute exactly one
  Job, then destroyed (ADR 0003; `CONTEXT.md`). The Runner record is created by
  the Provisioner *before* the container boots, carrying the credentials the
  Runner presents when it connects back over its Channel.

  - **Boot Token** (`CONTEXT.md`): the one-time credential presented on first
    join. Burned at first use (`boot_token_used_at`), rejected on reuse,
    expiry, or unknown token. Proves "the Provisioner booted me".
  - **Session Token** (`CONTEXT.md`): issued at first join, persisted so the
    reply shape is final from day one. Authenticates rejoin — but the rejoin
    machinery itself is out of scope here (issue #10).

  This slice creates the record and burns the Boot Token at first join; it does
  not model Runner lifecycle state (no per-Runner state machine yet) — the
  Job's lifecycle is the source of truth a Runner serves.
  """
  use Ash.Resource,
    otp_app: :athanor,
    domain: Athanor.Pipelines,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "runners"
    repo Athanor.Repo
  end

  actions do
    defaults [:read, :update]

    # Created by the Provisioner before boot, for a specific Job. Generates a
    # single-use, short-lived Boot Token; the caller injects it into the
    # container.
    create :boot do
      primary? true
      accept [:job_id]

      argument :boot_token_ttl_seconds, :integer, default: 60

      change fn changeset, _context ->
        ttl = Ash.Changeset.get_argument(changeset, :boot_token_ttl_seconds)

        changeset
        |> Ash.Changeset.force_change_attribute(
          :boot_token,
          Athanor.Pipelines.Runner.random_token()
        )
        |> Ash.Changeset.force_change_attribute(
          :boot_token_expires_at,
          DateTime.add(DateTime.utc_now(), ttl, :second)
        )
      end
    end

    # First join: burn the Boot Token and issue a Session Token. Fails if the
    # token is already burned or expired (a duplicate/late join).
    update :join do
      require_atomic? false

      change fn changeset, _context ->
        runner = changeset.data

        cond do
          not is_nil(runner.boot_token_used_at) ->
            Ash.Changeset.add_error(changeset, field: :boot_token, message: "already used")

          DateTime.compare(DateTime.utc_now(), runner.boot_token_expires_at) == :gt ->
            Ash.Changeset.add_error(changeset, field: :boot_token, message: "expired")

          true ->
            changeset
            |> Ash.Changeset.force_change_attribute(:boot_token_used_at, DateTime.utc_now())
            |> Ash.Changeset.force_change_attribute(:joined_at, DateTime.utc_now())
            |> Ash.Changeset.force_change_attribute(
              :session_token,
              Athanor.Pipelines.Runner.random_token()
            )
        end
      end
    end
  end

  attributes do
    uuid_primary_key :id

    # The one-time Boot Token, presented at first join. Burned on use.
    attribute :boot_token, :string, allow_nil?: false, sensitive?: true
    attribute :boot_token_expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :boot_token_used_at, :utc_datetime_usec, allow_nil?: true

    # The Session Token, issued at first join. Authenticates rejoin (#10).
    attribute :session_token, :string, allow_nil?: true, sensitive?: true

    # When the Runner first connected.
    attribute :joined_at, :utc_datetime_usec, allow_nil?: true

    timestamps()
  end

  relationships do
    belongs_to :job, Athanor.Pipelines.Job, allow_nil?: false
  end

  identities do
    identity :unique_boot_token, [:boot_token]

    # One Runner per Job, enforced at the data layer (ADR 0003: one Runner
    # executes exactly one Job).
    identity :unique_job, [:job_id]
  end

  @doc false
  def random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
