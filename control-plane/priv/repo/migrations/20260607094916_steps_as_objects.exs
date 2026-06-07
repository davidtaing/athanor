defmodule Athanor.Repo.Migrations.StepsAsObjects do
  @moduledoc """
  Steps become objects `{command, name?}` at the Definition, in storage, and on
  the wire (PRD #35, issue #37). This migrates the `jobs.steps` column from a
  `text[]` of bare shell strings to a `jsonb` array of Step objects, converting
  every existing stored step `"<command>"` to `{"command": "<command>"}`.

  Postgres disallows subqueries in an `ALTER COLUMN ... USING` transform, so the
  conversion runs through a temporary column populated by an `UPDATE`.
  """

  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :steps_objects, :jsonb, null: false, default: "[]"
    end

    # Map each bare-string step "<cmd>" to {"command": "<cmd>"}, preserving order.
    execute("""
    UPDATE jobs
    SET steps_objects = coalesce(
      (
        SELECT jsonb_agg(jsonb_build_object('command', step) ORDER BY ord)
        FROM unnest(steps) WITH ORDINALITY AS s(step, ord)
      ),
      '[]'::jsonb
    )
    """)

    alter table(:jobs) do
      remove :steps
    end

    rename table(:jobs), :steps_objects, to: :steps
  end

  def down do
    alter table(:jobs) do
      add :steps_strings, {:array, :text}, null: false, default: []
    end

    # Map each {"command": "<cmd>", ...} object back to its bare command string.
    execute("""
    UPDATE jobs
    SET steps_strings = coalesce(
      (
        SELECT array_agg(elem ->> 'command' ORDER BY ord)
        FROM jsonb_array_elements(steps) WITH ORDINALITY AS e(elem, ord)
      ),
      ARRAY[]::text[]
    )
    """)

    alter table(:jobs) do
      remove :steps
    end

    rename table(:jobs), :steps_strings, to: :steps
  end
end
