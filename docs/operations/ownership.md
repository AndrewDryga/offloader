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

## Support exclusions

The support response-time target covers Offloader's own behavior, not the
environment around it. Upstream pipeline failures and bad or incomplete
manifests are the data producer's to fix. IAM and network changes, object-store
outages, and insufficient disk, memory, or CPU belong to the team running the
environment. Unsupported config changes, data-modeling work, and custom
connector work outside a signed SOW aren't covered either.
