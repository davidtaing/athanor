defmodule Athanor.Accounts do
  @moduledoc """
  The Accounts domain: users, tokens, and API keys for control-plane auth.
  """
  use Ash.Domain, otp_app: :athanor, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Athanor.Accounts.Token
    resource Athanor.Accounts.User
    resource Athanor.Accounts.ApiKey
  end
end
