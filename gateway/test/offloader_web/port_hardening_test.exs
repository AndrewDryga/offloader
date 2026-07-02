defmodule OffloaderWeb.PortHardeningTest do
  use ExUnit.Case, async: true

  # The runtime "admin surface not on the API port" invariant is proven at the HTTP
  # boundary in the security suite (S01) and the health tests; here we lock in the
  # config-level guarantee that the two endpoints are genuinely separate ports.
  test "the API and admin endpoints are configured on separate ports" do
    api = OffloaderWeb.ApiEndpoint.config(:http)[:port]
    admin = OffloaderWeb.AdminEndpoint.config(:http)[:port]

    assert is_integer(api) and is_integer(admin)
    assert api != admin
  end
end
