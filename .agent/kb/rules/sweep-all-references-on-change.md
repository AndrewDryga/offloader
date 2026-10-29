# Sweep every reference when you change a shared value

**Rule:** When you change a default, name, port, tag, or any value that appears in more than one
place, grep the WHOLE repo (code, tests, docs, site, examples, deploy manifests, workflows) for
every reference and update them all in the same change — then verify end-to-end, including
downstream effects (CI, the Pages deploy, the published binary/image). Never ship a change that
leaves a stale or broken example behind.

**Why:** (A.D., 2026-07-04) Changing `offloader serve`'s default host port to 8088 left `:4000`
scattered across the landing page and docs, and separately a workflow change broke the Pages
deploy so a corrected hero never went live — the user hit non-working copy-paste examples twice.
Verbatim: "NEVER NEVER LEAVE NON WORKING THINGS BEHIND YOUR CHANGES."

**How to apply:**
- Before committing a value change, run `git grep -nE '<old-value>'` across the whole repo (do not
  scope to the files you happened to touch) and fix — or consciously justify — every hit.
- Distinguish canonical from contextual: the container's port is 4000 (Dockerfile/deploy); `serve`
  remaps the host to 8088. Update the serve/demo surfaces, leave the canonical ones, and say why.
- Verify downstream, not just the diff: if you touch `site/**`, confirm the Pages deploy actually
  SUCCEEDS (it can fail on a concurrent-deploy race — re-run it); if you touch the CLI, confirm the
  released binary carries the change; if you add a response field, update the OpenAPI + examples.
- Keep paired mirrors in sync: `docs/*.md` ↔ `site/docs/*.html`, and the real response ↔ its
  OpenAPI/docs example.
