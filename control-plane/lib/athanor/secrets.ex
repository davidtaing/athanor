defmodule Athanor.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Athanor.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:athanor, :token_signing_secret)
  end
end
