# Offloader marketing site

A self-contained marketing page plus a browsable docs site. No framework —
`index.html` + `styles.css` + a tiny `app.js`, the rendered docs under
`docs/`, with fonts, favicon, and the OG image all served from this folder.
Public pages load Mixpanel through `analytics.js`; booking-link clicks measure
intent, not completed bookings. ROI calculator inputs are not sent as events.

## Preview

```sh
# open directly
open index.html
# …or serve (nicer for relative links)
python3 -m http.server -d . 8080   # then http://localhost:8080
```

## Docs

The site's doc links point at `docs/*.html` — a browsable, on-brand rendering of the
repo's `docs/*.md` (the committed source of truth). The generated pages are committed so
the site deploys with no build step. Regenerate after editing any doc:

```sh
cd ../dev/docs-site && npm ci && npm run build
npm run check   # read-only comparison of docs HTML and sitemap with their sources
```

The generator (`dev/docs-site/build.mjs`) reuses this site's `styles.css` tokens plus
`docs.css`, so the docs inherit the same type, color, and light/dark behavior. It renders
the customer-facing docs only; internal planning docs stay out of the public site.
The same inventory, plus every top-level `site/*.html` page, generates `sitemap.xml`. Both CI and the Pages workflow reject
stale output. Existing `.html` URLs remain canonical, including `/docs/index.html`.

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

`fonts/` contains [Space Grotesk](https://github.com/floriankarsten/space-grotesk) (500, 600,
700) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (400, 500), both under the
**SIL Open Font License 1.1**; each family's license ships next to it (`*-OFL.txt`). Each file is
one weight of the family's variable font, trimmed to the Latin set plus the arrows block
(U+2190–21FF). `../dev/scripts/site-fonts.py` rebuilds them from the pinned sources.

Long documentation pages get an “On this page” disclosure from their level-two
headings. Keep those headings useful as navigation labels. Wide tables stay
readable and scroll within the page on smaller screens. Both behaviors are
shared in `dev/docs-site/build.mjs` and `site/docs.css`.
