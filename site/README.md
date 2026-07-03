# Offloader marketing site

A single, self-contained marketing page. No framework, no build step, no CDN, no
tracking — just `index.html` + `styles.css` + a tiny `app.js`, with fonts and the OG
image served from this folder.

## Preview

```sh
# open directly
open index.html
# …or serve (nicer for relative links)
python3 -m http.server -d . 8080   # then http://localhost:8080
```

The doc links (`../docs/*.md`) resolve when `site/` and `docs/` are siblings, as they are
in this repo.

## Design

- **Direction:** "the cost of repetition" — typography-led editorial, one signature device
  (the monospace cost-ledger in the hero, which counts up on load), real product artifacts
  as proof (a response carrying `snapshot_id`/freshness, the compiled-in tenant filter).
- **Type:** Space Grotesk (display) + JetBrains Mono (mono, a co-lead voice) + the system
  sans stack (body). Ink / warm paper + a single terracotta accent. Light and dark.
- **Constraints kept:** honest claims only (freshness is minutes–hours, not real-time; no
  hosted cloud; benchmark numbers are footnoted as relative). Accessible (skip link, semantic
  heading order, visible focus, `prefers-reduced-motion`, AA contrast). Responsive.

## Fonts (self-hosted, OFL)

`fonts/` contains [Space Grotesk](https://github.com/floriankarsten/space-grotesk) and
[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), both under the **SIL Open Font
License 1.1**. For a production deploy, ship the upstream `OFL.txt` alongside these files to
satisfy the license's bundling requirement.
