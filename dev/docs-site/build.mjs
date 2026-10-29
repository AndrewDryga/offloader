// Render the customer-facing docs/*.md into browsable, on-brand site/docs/*.html.
//
// Source of truth stays docs/*.md (committed, gated by dev/scripts/docs-check.sh).
// This pre-renders them to static HTML that reuses the marketing site's design
// system (site/styles.css tokens + site/docs.css). Server-rendered and crawlable —
// no client-side markdown, no framework.
//
//   cd dev/docs-site && npm ci && npm run build   # `npm run check` verifies without writing
//
// The generated site/docs/*.html is committed; re-run this after editing any doc.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync, statSync } from "node:fs";
import { dirname, join, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");
const OUT = join(ROOT, "site", "docs");
const REPO = "https://github.com/AndrewDryga/offloader";
const ORIGIN = "https://offloader.dryga.com";
const CHECK = process.argv.includes("--check");
const outputs = new Map();

// The docs site: ordered groups → pages. Each page is
// [slug, source (repo-relative), sidebar title, one-line blurb for the index, meta description].
// The meta description is what search results show under the title: a complete sentence of at
// most 155 characters, so it is never cut mid-thought.
const GROUPS = [
  {
    name: "Start",
    items: [
      ["concepts", "docs/concepts.md", "How Offloader works", "From warehouse exports to REST requests, with the terms you need to get started.",
        "Offloader serves REST APIs from snapshots of your warehouse data, on your own servers. Learn how datasets, endpoints and snapshots fit together."],
      ["quickstart", "docs/quickstart.md", "Quickstart", "Boot the bundled example and serve a real endpoint in about 15 minutes.",
        "Run Offloader with sample data, call a REST endpoint and watch it reject an invalid request. You need Docker, Git and about 15 minutes."],
    ],
  },
  {
    name: "Configure",
    items: [
      ["developer-experience", "docs/developer-experience.md", "Config guide", "Define datasets, endpoints, and keys; load config from disk or a bucket.",
        "Write an Offloader project: datasets, endpoints and API keys. Scaffold and validate it, then load it from disk or a bucket and reload it live."],
      ["config-reference", "docs/config-reference.md", "Config reference", "Every config field, accepted value, and example shape.",
        "Every field of an Offloader project and its allowed values: offloader.yml, datasets, endpoints and API keys, plus a working example to copy."],
      ["cli", "docs/cli.md", "CLI reference", "The optional `offloader` helper: every command, its flags, and an example.",
        "The optional offloader command-line helper: scaffold a project, validate its config, mint API keys and diagnose a deployment. The server does not need it."],
      ["api", "docs/api.md", "API reference", "Requests, responses, authentication, and HTTP error codes.",
        "What your product code sees when it calls an Offloader endpoint: requests, responses, authentication, pagination and HTTP error codes."],
    ],
  },
  {
    name: "Serve",
    items: [
      ["public-serving", "docs/public-serving.md", "Public data & CDN", "Serve public product data at the edge: cache headers, ETags, CORS.",
        "Serve public product data such as leaderboards and stats pages from Offloader, and cache it at a CDN: cache headers, ETags, CORS and purges."],
      ["mcp", "docs/mcp.md", "AI agents (MCP)", "Serve the same endpoints to AI agents over the Model Context Protocol.",
        "Let AI agents read your Offloader endpoints over the Model Context Protocol, alongside the REST API your app already calls."],
      ["security-model", "docs/security-model.md", "Security model", "What Offloader enforces for you, and what stays your responsibility.",
        "What Offloader enforces for you, such as read-only access, tenant isolation and hashed API keys, and what stays your responsibility."],
    ],
  },
  {
    name: "Operate",
    items: [
      ["deployment", "docs/deployment.md", "Deploy", "Deploy with Docker, Compose, or Kubernetes, then check the running service.",
        "Deploy the Offloader container with Docker, Compose or Kubernetes: the image, environment variables, config mounts, health checks and smoke tests."],
      ["operator", "docs/operator.md", "Operator guide", "Run it in production: size it, upgrade, roll back, diagnose.",
        "Run Offloader in production: size it, upgrade and roll back, follow snapshot refreshes, and read the diagnostics when something looks wrong."],
      ["runbooks", "docs/operations/runbooks.md", "Runbooks", "Step-by-step responses to the alerts that can fire.",
        "Step-by-step responses to Offloader alerts: tell an Offloader bug from an environment or upstream data problem, then act and escalate."],
      ["ownership", "docs/operations/ownership.md", "Ownership & support", "What your team operates and how to get support.",
        "Offloader runs in your environment, so incidents split three ways. This matrix shows what your team operates and how to get support."],
    ],
  },
  {
    name: "Evaluate",
    items: [
      ["warehouse-to-api", "docs/warehouse-to-api.md", "Warehouse to API", "Evaluate one customer-facing endpoint using a published snapshot.",
        "If your API can return data that is minutes or hours old, serve it from a warehouse snapshot instead of querying the warehouse on every request."],
      ["warehouse-cache-or-snapshot", "docs/warehouse-cache-or-snapshot.md", "Choose a serving path", "Compare direct warehouse queries, response caching and snapshot serving.",
        "Use direct warehouse queries for fresh or ad-hoc data, a response cache for repeated requests, and snapshots when many requests can share one dataset."],
      ["benchmarks", "docs/benchmarks.md", "Benchmarks", "Measure latency, throughput, and footprint on your own data.",
        "Measure Offloader on your own data before a pilot: load time, memory, disk, and p50, p95 and p99 latency at 1, 10 and 50 concurrent requests."],
    ],
  },
];

const FLAT = GROUPS.flatMap((g) => g.items.map((it) => ({ group: g.name, slug: it[0], src: it[1], title: it[2], blurb: it[3], description: it[4] })));
const longDescriptions = FLAT.filter((p) => !p.description || p.description.length > 155);
if (longDescriptions.length) {
  console.error(`docs-site: every page needs a meta description of at most 155 characters in GROUPS: ${longDescriptions.map((p) => p.slug).join(", ")}`);
  process.exit(1);
}
const BY_SRC = new Map(FLAT.map((p) => [p.src, `${p.slug}.html`])); // repo-rel source → output filename

// ── on-brand flow diagrams ──────────────────────────────────────────────────
// These figures are pure CSS (styled by site/styles.css + docs.css) — they render
// beautifully on the site, but GitHub's markdown sanitizer strips the class hooks
// they rely on, collapsing them to unstyled text. So the docs *source* carries a
// readable ASCII fallback inside a ```flow <id>``` fence (clean on GitHub and in any
// md viewer), and we splice the real figure back in here before marked runs — the
// site output stays byte-identical to inlining the HTML. Editing a diagram means
// updating BOTH the ASCII fence in the doc AND its HTML here, or the two surfaces drift.
const FIGURES = {
  "warehouse-vs-offloader": `<figure class="flow flow-contrast" aria-label="Before: every request hits the data warehouse. After: every request hits Offloader on your servers, which reads from a published snapshot in object storage.">
  <div class="flow-lane">
    <span class="lane-tag lane-before">Before</span>
    <div class="flow-track">
      <div class="node"><span class="node-k">Every request</span><strong>Your app</strong></div>
      <div class="hop"><span class="hop-l">warehouse query</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node node-warn"><span class="node-k">Data warehouse</span><strong>Query execution</strong><span class="node-sub">warehouse work per request</span></div>
    </div>
  </div>
  <div class="flow-lane">
    <span class="lane-tag lane-after">After</span>
    <div class="flow-track">
      <div class="node"><span class="node-k">Every request</span><strong>Your app</strong></div>
      <div class="hop"><span class="hop-l">REST API</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node node-hero"><span class="node-k">Your servers</span><strong>Offloader</strong><span class="node-sub">no warehouse work per request</span></div>
      <div class="hop"><span class="hop-l">reads</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node"><span class="node-k">Object store</span><strong>Snapshot</strong><span class="node-sub">S3 · GCS</span></div>
    </div>
  </div>
</figure>`,
  "snapshot-pipeline": `<figure class="flow" aria-label="Default local_table mode: your pipeline exports a snapshot to object storage; Offloader checks the configured snapshot, loads it into DuckDB, and serves REST.">
  <div class="flow-track">
    <div class="node node-batch"><span class="node-k">On your schedule</span><strong>Your pipeline</strong><span class="node-sub">warehouse export</span></div>
    <div class="hop hop-batch"><span class="hop-l">export</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node"><span class="node-k">Object store</span><strong>Parquet + manifest</strong><span class="node-sub">S3 · GCS</span></div>
    <div class="hop"><span class="hop-l">load locally</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node node-hero"><span class="node-k">Your servers</span><strong>Offloader · DuckDB</strong><span class="node-sub">loads the configured snapshot</span></div>
    <div class="hop hop-rev"><span class="hop-l">REST</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node"><span class="node-k">Every request</span><strong>Your app</strong><span class="node-sub">no warehouse call</span></div>
  </div>
  <figcaption class="flow-cap"><span class="flow-mark" aria-hidden="true">↻</span> The default mode loads the configured snapshot into DuckDB. Your export job uses the warehouse; customer requests use the snapshot.</figcaption>
</figure>`,
  "two-ports": `<figure class="flow" aria-label="Product traffic hits the API port (4000), guarded by endpoint API keys and tenant enforcement. Operators hit a separate admin port (4001) for health, metrics, diagnostics, and docs — keep it private.">
  <div class="ports">
    <div class="node node-hero"><span class="node-k">Product traffic</span><strong>API port · 4000</strong><span class="node-sub">endpoint API keys · tenant enforcement</span></div>
    <div class="node"><span class="node-k">Operators — keep private</span><strong>Admin port · 4001</strong><span class="node-sub">health · metrics · diagnostics · docs</span></div>
  </div>
</figure>`,
};

// Replace each ```flow <id>``` fence with its figure HTML, raw — so marked passes it
// through exactly as if the HTML were inline (identical to the pre-fence source).
function expandFlowFigures(md, srcRepoRel) {
  return md.replace(/^```flow[ \t]+([\w-]+)[ \t]*\r?\n[\s\S]*?\r?\n```[ \t]*$/gm, (_block, id) => {
    const fig = FIGURES[id];
    if (!fig) throw new Error(`docs-site: unknown flow figure "${id}" in ${srcRepoRel} — add it to FIGURES in build.mjs`);
    return fig;
  });
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// GitHub's heading slug (github-slugger), so a #anchor works on the site and on GitHub alike:
// the heading's plain text, lowercased, keeping only letters, marks, numbers, underscores,
// hyphens and spaces, then each space made a hyphen ("A — B" → "a--b"). Decoded first, or an
// escaped apostrophe (&#39;) would leave "39" behind.
function slugify(html) {
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/&(?:amp|lt|gt|quot|#39);/g, (e) => ENTITIES[e])
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "")
    .replace(/ /g, "-");
}

// Add id="" to every heading (dedup like GitHub: -1, -2, …).
function addHeadingIds(html) {
  const seen = new Map();
  return html.replace(/<h([1-6])>([\s\S]*?)<\/h\1>/g, (_m, lvl, inner) => {
    const base = slugify(inner) || "section";
    const n = seen.get(base) || 0;
    seen.set(base, n + 1);
    const id = n === 0 ? base : `${base}-${n}`;
    return `<h${lvl} id="${id}">${inner}</h${lvl}>`;
  });
}

// Rewrite a link found in `srcRepoRel`: .md → .html within the rendered set,
// repo files → GitHub source, external/anchors left alone.
function resolveHref(href, srcRepoRel) {
  if (/^(https?:|mailto:|#)/.test(href)) return href;
  const hash = href.indexOf("#");
  const path = hash === -1 ? href : href.slice(0, hash);
  const anchor = hash === -1 ? "" : href.slice(hash);
  if (path === "") return href;
  const target = posix.normalize(posix.join(posix.dirname(srcRepoRel), path));
  if (BY_SRC.has(target)) return BY_SRC.get(target) + anchor;
  const localTarget = join(ROOT, target);
  const isDir = existsSync(localTarget)
    ? statSync(localTarget).isDirectory()
    : path.endsWith("/") || !posix.basename(target).includes(".");
  return `${REPO}/${isDir ? "tree" : "blob"}/main/${target}${anchor}`;
}

function rewriteLinks(html, srcRepoRel) {
  return html.replace(/(<a\b[^>]*\bhref=")([^"]+)(")/g, (_m, pre, href, post) => pre + resolveHref(href, srcRepoRel) + post);
}

// Wide tables and long code blocks scroll horizontally. Make those scroll containers
// keyboard-focusable (WCAG 2.1.1 — a keyboard-only user must be able to reach clipped
// content) and keep the table's real semantics: wrap it rather than setting
// display:block on the <table>, which would strip its row/cell roles for screen readers.
function makeScrollRegionsFocusable(html) {
  return html
    .replace(/<pre>/g, '<pre tabindex="0">')
    .replace(/<table>/g, '<div class="table-scroll" tabindex="0">\n<table>')
    .replace(/<\/table>/g, "</table>\n</div>");
}

// A compact contents disclosure keeps long guides easy to scan. It follows the opening paragraph,
// so a phone shows it on the first screen however long the rest of the intro runs.
function addContents(html) {
  const headings = [...html.matchAll(/<h2 id="([^"]+)">([\s\S]*?)<\/h2>/g)];
  if (headings.length < 3) return html;
  const links = headings.map(([, id, text]) => `<li><a href="#${id}">${text.replace(/<a\b[^>]*>|<\/a>/g, "")}</a></li>`).join("\n");
  const contents = `<details class="doc-contents"><summary>On this page</summary><nav aria-label="On this page"><ul>${links}</ul></nav></details>\n`;
  const lede = html.match(/<\/h1>\s*<p>[\s\S]*?<\/p>\n?/);
  const at = lede ? lede.index + lede[0].length : html.indexOf("<h2 ");
  return html.slice(0, at) + contents + html.slice(at);
}

// Plain text for <title> and meta tags. Undo marked's HTML escaping in one pass, so esc()
// escapes the text only once (an apostrophe stays an apostrophe), and join it into one line.
const ENTITIES = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'" };
const firstText = (html, tag) => {
  const m = html.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`));
  return m ? m[1].replace(/<[^>]+>/g, "").replace(/&(?:amp|lt|gt|quot|#39);/g, (e) => ENTITIES[e]).replace(/\s+/g, " ").trim() : "";
};

// ── shared chrome ─────────────────────────────────────────────────────────
const BRAND_MARK = `<svg class="brand-mark" width="1em" height="1em" viewBox="0 0 10 10" aria-hidden="true" focusable="false"><rect width="4.4" height="4.4" rx="0.6" fill="currentColor"/><rect x="5.6" y="5.6" width="4.4" height="4.4" rx="0.6" fill="currentColor"/></svg>`;

// Same links, order, and CTA as the marketing site's nav (site/index.html) — only the
// paths differ (docs live one level down). Keep the two in sync when either changes.
function header(active) {
  return `<header class="site" role="banner">
  <nav class="wrap nav" aria-label="Primary">
    <a class="brand" href="../index.html" aria-label="Offloader home">${BRAND_MARK}<span class="brand-word">Offloader</span></a>
    <ul class="nav-links">
      <li><a href="../index.html#how">How it works</a></li>
      <li><a href="../index.html#proof">Proof</a></li>
      <li><a href="../index.html#pricing">Pricing</a></li>
      <li><a href="../index.html#fit">Fit</a></li>
      <li><a href="index.html"${active === "docs" ? ' aria-current="true"' : ""}>Docs</a></li>
      <li><a href="https://cal.com/andrew-dryga/offloader" target="_blank" rel="noopener" class="nav-cta">Book a call</a></li>
    </ul>
  </nav>
</header>`;
}

function sidebar(activeSlug) {
  const groups = GROUPS.map((g) => {
    const links = g.items
      .map(([slug, , title]) => {
        const cur = slug === activeSlug;
        return `<li><a href="${slug}.html"${cur ? ' aria-current="page"' : ""}>${title}</a></li>`;
      })
      .join("\n        ");
    return `<div class="nav-group">
      <p class="nav-group-h">${g.name}</p>
      <ul>
        ${links}
      </ul>
    </div>`;
  }).join("\n    ");
  return `<details id="docsnav" class="docs-nav" open>
    <summary>Browse the docs</summary>
    <nav aria-label="Documentation">
    <a class="docs-home" href="index.html"${activeSlug === undefined ? ' aria-current="page"' : ""}>Docs home</a>
    ${groups}
    </nav>
  </details>`;
}

// Mirror of the marketing site's footer (site/index.html), path-adjusted for docs/.
// Styled by the shared styles.css (.site-foot …). Keep in sync with the landing footer.
const FOOT = `<footer class="site-foot">
  <div class="wrap foot-inner">
    <div class="foot-brand">
      <p class="foot-word">${BRAND_MARK} Offloader</p>
      <p class="foot-tag">If your warehouse can publish Parquet, Offloader can serve it through REST.</p>
      <p class="foot-copy">© 2026 Offloader</p>
    </div>
    <nav class="foot-nav" aria-label="Footer">
      <div>
        <h3>Product</h3>
        <a href="../index.html#how">How it works</a>
        <a href="../index.html#pricing">Pricing</a>
        <a href="../index.html#faq">FAQ</a>
      </div>
      <div>
        <h3>Docs</h3>
        <a href="concepts.html">Concepts</a>
        <a href="quickstart.html">Quickstart</a>
        <a href="cli.html">CLI reference</a>
        <a href="security-model.html">Security</a>
      </div>
      <div>
        <h3>Evaluate</h3>
        <a href="../roi.html">ROI calculator</a>
        <a href="benchmarks.html">Benchmarks</a>
      </div>
      <div>
        <h3>Talk to us</h3>
        <a href="https://cal.com/andrew-dryga/offloader" target="_blank" rel="noopener">Book a call</a>
        <a href="${REPO}">GitHub</a>
      </div>
    </nav>
  </div>
</footer>`;

// Collapse the docs list on narrow screens; keep it open on wide ones. Re-evaluates on
// resize/rotate. Enhancement only — without JS the <details open> leaves the nav usable.
const NAV_COLLAPSE = `<script>(function(){var n=document.getElementById('docsnav');if(!n)return;var q=matchMedia('(max-width: 980px)');function s(){n.open=!q.matches;}s();q.addEventListener('change',s);})();</script>`;

function page({ title, description, active, activeSlug, main }) {
  const canonical = `${ORIGIN}/docs/${activeSlug || "index"}.html`;
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${canonical}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="Offloader">
<meta property="og:url" content="${canonical}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${ORIGIN}/og.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="../favicon.svg" type="image/svg+xml">
<link rel="preload" as="font" type="font/woff2" href="../fonts/SpaceGrotesk-700.woff2" crossorigin>
<link rel="stylesheet" href="../styles.css">
<link rel="stylesheet" href="../docs.css">
<script src="../analytics.js" defer></script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
${header(active)}
<div class="wrap docs-layout">
  ${sidebar(activeSlug)}
  <main id="main" class="docs-main">
${main}
  </main>
</div>
${FOOT}
${NAV_COLLAPSE}
</body>
</html>
`;
}

// ── render each doc ────────────────────────────────────────────────────────
marked.setOptions({ gfm: true });

const bodies = new Map(); // `<slug>.html` → { src, body }, for the anchor check below

for (let i = 0; i < FLAT.length; i++) {
  const p = FLAT[i];
  const md = expandFlowFigures(readFileSync(join(ROOT, p.src), "utf8"), p.src);
  let body = marked.parse(md);
  body = addHeadingIds(body);
  body = rewriteLinks(body, p.src);
  body = makeScrollRegionsFocusable(body);
  body = addContents(body);
  bodies.set(`${p.slug}.html`, { src: p.src, body });

  const h1 = firstText(body, "h1") || p.title;

  const prev = FLAT[i - 1];
  const next = FLAT[i + 1];
  const pager = `<nav class="doc-pager" aria-label="Pagination">
      ${prev ? `<a class="pg prev" href="${prev.slug}.html"><span>Previous</span><b>${prev.title}</b></a>` : "<span></span>"}
      ${next ? `<a class="pg next" href="${next.slug}.html"><span>Next</span><b>${next.title}</b></a>` : "<span></span>"}
    </nav>`;

  const main = `    <p class="doc-kicker">${p.group}</p>
    <article class="prose">
${body}</article>
    ${pager}`;

  outputs.set(join(OUT, `${p.slug}.html`), page({
    title: `${h1} — Offloader docs`,
    description: p.description,
    active: "docs",
    activeSlug: p.slug,
    main,
  }));
}

// Every #anchor a docs page links to, on itself or on another docs page, must exist there; a
// renamed heading would otherwise break its links without a sound.
const idsOf = new Map([...bodies].map(([file, { body }]) => [file, new Set([...body.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]))]));
const brokenAnchors = [...bodies].flatMap(([file, { src, body }]) =>
  [...body.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)]
    .map(([, href]) => [href, href.match(/^([\w-]+\.html)?#(.+)$/)])
    .filter(([, m]) => m && idsOf.has(m[1] || file) && !idsOf.get(m[1] || file).has(m[2]))
    .map(([href]) => `${src} → ${href}`));
if (brokenAnchors.length) {
  console.error(`docs-site: links to anchors that don't exist:\n  ${brokenAnchors.join("\n  ")}`);
  process.exit(1);
}

// ── index ──────────────────────────────────────────────────────────────────
const cards = GROUPS.map((g) => {
  const items = g.items
    .map(([slug, , title, blurb]) => `      <li><a href="${slug}.html"><b>${title}</b><span>${blurb}</span></a></li>`)
    .join("\n");
  return `    <section class="doc-group">
      <h2>${g.name}</h2>
      <ul class="doc-index">
${items}
      </ul>
    </section>`;
}).join("\n");

const indexMain = `    <header class="docs-hero">
      <p class="doc-kicker">Documentation</p>
      <h1>Run Offloader from first boot to production.</h1>
      <p class="lede">Serve repeated product API reads from warehouse snapshots on your own
      servers. New here? Start with
      <a href="concepts.html">how Offloader works</a>, then run the
      <a href="quickstart.html">15-minute quickstart</a>.</p>
    </header>
${cards}`;

outputs.set(join(OUT, "index.html"), page({
  title: "Documentation — Offloader",
  description: "Run Offloader from first boot to production: concepts, quickstart, config and API reference, security, deployment, and ROI.",
  active: "docs",
  activeSlug: undefined,
  main: indexMain,
}));

// One inventory drives navigation, generated pages, and discovery; every hand-written page at the
// top of site/ is listed too, sorted so the file is the same on every OS. Omit lastmod: a build
// date is not evidence that the page's substance changed.
const topLevel = readdirSync(join(ROOT, "site"))
  .filter((name) => name.endsWith(".html"))
  .sort()
  .map((name) => (name === "index.html" ? "/" : `/${name}`));
const paths = [...topLevel, "/docs/index.html", ...FLAT.map((p) => `/docs/${p.slug}.html`)];
outputs.set(join(ROOT, "site", "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
  paths.map((path) => `  <url><loc>${ORIGIN}${path}</loc></url>`).join("\n") +
  "\n</urlset>\n");

const unexpected = existsSync(OUT)
  ? readdirSync(OUT).filter((name) => name.endsWith(".html") && !outputs.has(join(OUT, name)))
  : [];
if (unexpected.length) {
  console.error(`docs-site: unlisted public HTML: ${unexpected.join(", ")}. Nothing was written. Delete the file (its URL will 404) or add the page to GROUPS.`);
  process.exitCode = 1;
}
if (CHECK) {
  const stale = [...outputs].filter(([path, content]) =>
    !existsSync(path) || readFileSync(path, "utf8") !== content);
  for (const [path] of stale) console.error(`docs-site: stale or missing ${path.slice(ROOT.length + 1)}`);
  if (stale.length) process.exitCode = 1;
  else if (!unexpected.length) console.log(`docs-site: ${outputs.size} generated files are current`);
} else if (!unexpected.length) {
  mkdirSync(OUT, { recursive: true });
  for (const [path, content] of outputs) writeFileSync(path, content);
  console.log(`docs-site: rendered ${FLAT.length} pages + index and sitemap`);
}
