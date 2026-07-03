# Customer-run ownership matrix and support exclusions

Offloader runs in the customer's environment, so incidents split three ways. This
matrix is the first thing to consult in an incident — it keeps a customer-environment
or upstream-data problem from being mis-filed as an Offloader bug (and vice-versa).

| Area | Offloader owns | Customer owns |
| --- | --- | --- |
| The serving container | Bugs in auth, tenant enforcement, compiler, refresh, materialization, diagnostics. | Running it, its resources (CPU/memory/disk), and restarts. |
| Config | The config *contract* + validation. | The config *content* (datasets, endpoints, keys) and keeping it correct. |
| Snapshots/manifests | Validating them and never serving partial/breaking data. | Producing correct, fresh, approved manifests upstream. |
| Object store / source | Reading it read-only when reachable. | Its availability, IAM, credentials, and network path. |
| Ports & exposure | Two separate ports + redaction. | Network, proxy, TLS, IAM, and keeping the admin port private. |
| Identity | API keys, endpoint scopes, tenant binding. | Admin-port access control (their own network/IAM), and key distribution. |

## Support exclusions (V1)

These are the customer's, not covered by an Offloader support response target
(a response-time target, not an uptime SLA in V1):

- Upstream pipeline failures; bad or incomplete manifests.
- Customer IAM/network changes; object-store outages.
- Insufficient disk, memory, or CPU.
- Unsupported config changes.
- Data modeling work; custom connector work outside a signed SOW.

## Classify in under five minutes

1. `curl $ADMIN/ready` — is the instance serving at all?
2. `DIAG` — per dataset: `last_attempted.status`, `refresh_error`, `source_reachable`,
   `stale`, `duckdb_status`, `disk`.
3. Map the failing signal to the matrix above → owner → the matching runbook.
