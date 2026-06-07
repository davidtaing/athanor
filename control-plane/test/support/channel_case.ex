defmodule AthanorWeb.ChannelCase do
  @moduledoc """
  Test case for the Runner Channel seam — exercises real Channels via Phoenix's
  channel-testing tooling (MVP PRD testing seam 2).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AthanorWeb.Endpoint

      import Phoenix.ChannelTest
      import AthanorWeb.ChannelCase
    end
  end

  setup tags do
    Athanor.DataCase.setup_sandbox(tags)
    :ok
  end
end
