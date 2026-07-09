# Documentation

Start with **[What Offloader is, in plain language](concepts.md)**, then pick what
you need next. Docs are versioned with the code, so claims and behavior move
together.

## For customers

| Doc | What it covers |
| --- | --- |
| **[concepts.md](concepts.md)** | What Offloader is, when it fits, and the few terms the other docs use. **Start here.** |
| [quickstart.md](quickstart.md) | Run it against the bundled example in ~15 minutes, no cloud needed. |
| [developer-experience.md](developer-experience.md) | Config guide: define datasets, endpoints, and keys; load config from disk or a bucket. |
| [config-reference.md](config-reference.md) | Field-by-field reference for every config file, accepted value, and example shape. |
| [cli.md](cli.md) | The optional `offloader` helper: every command, its flags, and an example. |
| [api.md](api.md) | The consumer API contract: request, the `data`/`meta` envelope, and the error-to-status table. |
| [operator.md](operator.md) | Run it in production: deploy, size, upgrade, roll back, diagnose. |
| [deployment.md](deployment.md) | Deployment shapes (docker / Compose / Kubernetes) and rollout verification. |
| [security-model.md](security-model.md) | What Offloader protects for you, and what you're responsible for. |
| [public-serving.md](public-serving.md) | Serve public data to a front-end and cache it at the edge (auth, ETags, CORS). |
| [benchmarks.md](benchmarks.md) | Measure latency, throughput, and footprint on your own data. |

## Deeper reference

| Doc | What it covers |
| --- | --- |
| [architecture.md](architecture.md) | Data-plane decisions, runtime pipeline, ports, manifest contract. |
| [release.md](release.md) | Release packaging, SBOM, and provenance. |

Operational procedures live under [`operations/`](operations/) (runbooks, dashboards, alerts).
