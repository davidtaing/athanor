defmodule Athanor.Pipelines.RunnerTest do
  @moduledoc """
  The Runner resource. Focus: the derived Boot Token TTL (PRD #35, issue #37) —
  TTL = boot timeout + one sweep interval, computed at token creation from the
  two existing config values, never an independent knob. At defaults that is
  60 s + 30 s = 90 s. A TTL equal to the boot timeout would reject legitimate
  late joins the sweep would still accept.
  """
  use Athanor.DataCase, async: true

  alias Athanor.Pipelines
  alias Athanor.Pipelines.Runner

  setup do
    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: [%{name: "build", image: "alpine:3", steps: [%{"command" => "make"}]}]
      })

    [job] = Ash.load!(pipeline, :jobs).jobs
    {:ok, job: job}
  end

  defp boot(job) do
    Runner
    |> Ash.Changeset.for_create(:boot, %{job_id: job.id})
    |> Ash.create!()
  end

  test "the Boot Token TTL is derived = boot timeout + one sweep interval (90 s at defaults)",
       %{job: job} do
    before = DateTime.utc_now()
    runner = boot(job)

    expected_ttl_seconds =
      div(Application.fetch_env!(:athanor, :boot_timeout), 1000) +
        div(Application.fetch_env!(:athanor, :scheduler_sweep_interval), 1000)

    assert expected_ttl_seconds == 90

    actual_ttl_seconds = DateTime.diff(runner.boot_token_expires_at, before, :second)

    # Allow a one-second window for clock drift across the action.
    assert_in_delta actual_ttl_seconds, expected_ttl_seconds, 1
  end
end
