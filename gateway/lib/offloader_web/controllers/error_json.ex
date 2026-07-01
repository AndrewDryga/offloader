defmodule OffloaderWeb.ErrorJSON do
  @moduledoc """
  Renders errors as stable JSON. Deliberately terse: a security error must not
  reveal whether a forbidden dataset/endpoint exists (see `docs/security-model.md`),
  so this returns only the generic HTTP status message. Named error families for
  the API surface are added by G05/G06.
  """

  # Turns a template like "404.json" into %{errors: %{detail: "Not Found"}}.
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
