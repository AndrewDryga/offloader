defmodule OffloaderWeb do
  @moduledoc """
  Entrypoint macros for the web layer (`use OffloaderWeb, :router` /
  `use OffloaderWeb, :controller`). Keep this thin: no HTML, no LiveView, no
  channels — the server is a JSON API with two endpoints (product + admin).
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
    end
  end

  @doc "Dispatch `use OffloaderWeb, :thing` to the matching macro above."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
