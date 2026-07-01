# docs

Product, architecture, security, operations, and release documentation. This is
the **committed source of truth**: a fresh agent or a buyer reads these to learn
what Offloader is, how it is built, and what "V1" means. Docs are versioned with
the code so a claim and the behavior that backs it move together.

## What lives here

| File | Owns |
| --- | --- |
| `architecture.md` | Data-plane decision, runtime pipeline, ports, manifest contract, security invariant. |
| `security-model.md` | P0 security requirements, customer-run boundary, required tests. |
| `developer-experience.md` | First-hour golden path, env-var contract, config layout. |
| `deployment.md` | Customer-run deployment shape and required examples. |

Later tasks add: `quickstart.md` (D01); operator, upgrade, and support pages
(D02); `operations/` runbooks, dashboards, and alert rules (O01); ROI report
format (P02); and pilot/procurement collateral (P03).

## Rules

- Docs are committed. Keep them true to shipped behavior — never a promise the
- One page per operator concern; link, do not duplicate (point at runbooks
  instead of restating them).
- No stale broad claims: not "works with every lakehouse", not Delta/Iceberg in
  V1, not hosted cloud, not RBAC/SSO. If the product boundary changes, change the
  boundary docs in the same commit.
