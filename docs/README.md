# Documentation

Start with **[What Offloader is, in plain language](concepts.md)**, then pick by what
you want to do. Docs are versioned with the code, so a claim and the behavior that
backs it move together.

> These customer docs are also rendered into a browsable, on-brand site under `site/docs/`
> (built by `dev/docs-site` — see its README). The Markdown here stays the source of truth.

## For customers

| Doc | What it covers |
| --- | --- |
| **[concepts.md](concepts.md)** | What Offloader is, why you'd want it, and the words the other docs use. **Start here.** |
| [quickstart.md](quickstart.md) | Run it against the bundled example in ~15 minutes, no cloud needed. |
| [developer-experience.md](developer-experience.md) | Config guide: define your datasets, endpoints, and keys; load config from a bucket. |
| [config-reference.md](config-reference.md) | Field-by-field reference for every config file, with the exact allowed values. |
| [api.md](api.md) | The consumer API contract: request, the `data`/`meta` envelope, and the error-to-status table. |
| [operator.md](operator.md) | Run it in production: deploy, size, upgrade, roll back, diagnose. |
| [deployment.md](deployment.md) | Deployment shapes (docker / Compose / Kubernetes) and rollout verification. |
| [security-model.md](security-model.md) | What Offloader protects for you, and what you're responsible for. |
| [public-serving.md](public-serving.md) | Serve public data to a front-end and cache it at the edge (auth, ETags, CORS). |
| [roi.md](roi.md) | Estimate the warehouse savings before committing. |
| [benchmarks.md](benchmarks.md) | Measure latency, throughput, and footprint on your own data. |


| Doc | What it covers |
| --- | --- |
| [architecture.md](architecture.md) | Data-plane decisions, runtime pipeline, ports, manifest contract. |
| [release.md](release.md) | Release packaging, SBOM, and provenance. |

Deeper procedures live under [`operations/`](operations/) (runbooks, dashboards, alerts)

## Rules

- Docs are committed and must stay true to shipped behavior — never a promise the code
  does not keep.
- One page per concern; **link, don't duplicate** (point at a runbook instead of
  restating it).
- No stale broad claims: not "works with every lakehouse", not hosted cloud, not
  RBAC/SSO in V1. If the product boundary changes, change the boundary docs in the same
  commit.
