# server - how we build

The server is the customer-run data plane: Phoenix REST API, endpoint contracts,
consumer API keys, tenant enforcement, manifest refresh supervision, DuckDB
materialization, and operational endpoints.

## Gate

Once the Phoenix app exists, run from `server/`:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

## Architecture rules

- Endpoint contracts are the public surface; DuckDB is an implementation detail.
- Serve product endpoints on the API port and health/diagnostics/metrics/docs on
  the admin port.
- No arbitrary SQL from consumers.
- Tenant filters are inserted by the compiler and cannot be overridden by params.
- Do not implement RBAC, SSO, teams, invitations, or a hosted control plane.
- Failed refresh preserves the previous good snapshot.
- Long-running refresh and cache workers are supervised.
- Logs and metrics redact secrets and raw credentialed paths.
