// Render the customer-facing docs/*.md into browsable, on-brand site/docs/*.html.
//
// Source of truth stays docs/*.md (committed, gated by dev/scripts/docs-check.sh).
// This pre-renders them to static HTML that reuses the marketing site's design
// system (site/styles.css tokens + site/docs.css). Server-rendered and crawlable —
// no client-side markdown, no framework.
//
//   cd dev/docs-site && npm install && npm run build
//
// The generated site/docs/*.html is committed; re-run this after editing any doc.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");
const OUT = join(ROOT, "site", "docs");
const REPO = "https://github.com/AndrewDryga/offloader";

// The docs site: ordered groups → pages. Each page is
// [slug, source (repo-relative), sidebar title, one-line blurb for the index].
const GROUPS = [
  {
    name: "Start",
    items: [
      ["concepts", "docs/concepts.md", "What Offloader is", "The short explanation, plus the few terms the rest of the docs use."],
      ["quickstart", "docs/quickstart.md", "Quickstart", "Boot the bundled example and serve a real endpoint in about 15 minutes."],
    ],
  },
  {
    name: "Configure",
    items: [
      ["developer-experience", "docs/developer-experience.md", "Config guide", "Define datasets, endpoints, and keys; load config from disk or a bucket."],
      ["config-reference", "docs/config-reference.md", "Config reference", "Every config field, accepted value, and example shape."],
      ["cli", "docs/cli.md", "CLI reference", "The optional `offloader` helper: every command, its flags, and an example."],
      ["api", "docs/api.md", "API reference", "The consumer request/response contract and the error-to-status-code table."],
    ],
  },
  {
    name: "Serve",
    items: [
      ["public-serving", "docs/public-serving.md", "Public data & CDN", "Serve public product data at the edge: cache headers, ETags, CORS."],
      ["security-model", "docs/security-model.md", "Security model", "What Offloader enforces for you, and what stays your responsibility."],
    ],
  },
  {
    name: "Operate",
    items: [
      ["deployment", "docs/deployment.md", "Deploy", "Docker, Compose, and Kubernetes shapes, with rollout verification."],
      ["operator", "docs/operator.md", "Operator guide", "Run it in production: size it, upgrade, roll back, diagnose."],
      ["runbooks", "docs/operations/runbooks.md", "Runbooks", "Step-by-step responses to the alerts that can fire."],
      ["ownership", "docs/operations/ownership.md", "Ownership & support", "The responsibility matrix for a deployment you run yourself."],
    ],
  },
  {
    name: "Evaluate",
    items: [
      ["benchmarks", "docs/benchmarks.md", "Benchmarks", "Measure latency, throughput, and footprint on your own data."],
    ],
  },
];

const FLAT = GROUPS.flatMap((g) => g.items.map((it) => ({ group: g.name, slug: it[0], src: it[1], title: it[2], blurb: it[3] })));
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
      <div class="node node-warn"><span class="node-k">Data warehouse</span><strong>$$$ · slow</strong><span class="node-sub">billed per query</span></div>
    </div>
  </div>
  <div class="flow-lane">
    <span class="lane-tag lane-after">After</span>
    <div class="flow-track">
      <div class="node"><span class="node-k">Every request</span><strong>Your app</strong></div>
      <div class="hop"><span class="hop-l">REST API</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node node-hero"><span class="node-k">Your servers</span><strong>Offloader</strong><span class="node-sub">cheap · fast</span></div>
      <div class="hop"><span class="hop-l">reads</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node"><span class="node-k">Object store</span><strong>Snapshot</strong><span class="node-sub">S3 · GCS</span></div>
    </div>
  </div>
</figure>`,
  "snapshot-pipeline": `<figure class="flow" aria-label="Your pipeline exports a snapshot to object storage; Offloader checks it, loads it into DuckDB, and serves REST; a newer valid snapshot replaces the old one.">
  <div class="flow-track">
    <div class="node node-batch"><span class="node-k">On your schedule</span><strong>Your pipeline</strong><span class="node-sub">warehouse export</span></div>
    <div class="hop hop-batch"><span class="hop-l">export</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node"><span class="node-k">Object store</span><strong>Parquet + manifest</strong><span class="node-sub">S3 · GCS</span></div>
    <div class="hop"><span class="hop-l">load locally</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node node-hero"><span class="node-k">Your servers</span><strong>Offloader · DuckDB</strong><span class="node-sub">loads the latest snapshot</span></div>
    <div class="hop hop-rev"><span class="hop-l">REST</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node"><span class="node-k">Every request</span><strong>Your app</strong><span class="node-sub">no warehouse call</span></div>
  </div>
  <figcaption class="flow-cap"><span class="flow-mark" aria-hidden="true">↻</span> A newer snapshot is checked before it replaces the old one — the warehouse is used by the export job, not by each customer request.</figcaption>
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

// GitHub-compatible heading slug, so existing in-doc #anchors keep resolving.
function slugify(text) {
  return text
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/&[a-z]+;/g, "")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
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
  const isDir = path.endsWith("/") || !posix.basename(target).includes(".");
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

const firstText = (html, tag) => {
  const m = html.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`));
  return m ? m[1].replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").trim() : "";
};

function truncate(s, n) {
  if (s.length <= n) return s;
  const cut = s.slice(0, n);
  return cut.slice(0, cut.lastIndexOf(" ")).replace(/[,.;:]$/, "") + "…";
}

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
      <li><a href="https://calendly.com/andrew-dryga/offloader" target="_blank" rel="noopener" class="nav-cta">Book a call</a></li>
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
        <a href="https://calendly.com/andrew-dryga/offloader" target="_blank" rel="noopener">Book a diagnostic</a>
        <a href="${REPO}">GitHub</a>
      </div>
    </nav>
  </div>
</footer>`;

// Collapse the docs list on narrow screens; keep it open on wide ones. Re-evaluates on
// resize/rotate. Enhancement only — without JS the <details open> leaves the nav usable.
const NAV_COLLAPSE = `<script>(function(){var n=document.getElementById('docsnav');if(!n)return;var q=matchMedia('(max-width: 980px)');function s(){n.open=!q.matches;}s();q.addEventListener('change',s);})();</script>`;

function page({ title, description, active, activeSlug, main }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
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
mkdirSync(OUT, { recursive: true });

for (let i = 0; i < FLAT.length; i++) {
  const p = FLAT[i];
  const md = expandFlowFigures(readFileSync(join(ROOT, p.src), "utf8"), p.src);
  let body = marked.parse(md);
  body = addHeadingIds(body);
  body = rewriteLinks(body, p.src);
  body = makeScrollRegionsFocusable(body);

  const h1 = firstText(body, "h1") || p.title;
  const desc = truncate(firstText(body, "p") || p.blurb, 155);

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

  writeFileSync(join(OUT, `${p.slug}.html`), page({
    title: `${h1} — Offloader docs`,
    description: desc,
    active: "docs",
    activeSlug: p.slug,
    main,
  }));
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
      <a href="concepts.html">what Offloader is</a>, then run the
      <a href="quickstart.html">15-minute quickstart</a>.</p>
    </header>
${cards}`;

writeFileSync(join(OUT, "index.html"), page({
  title: "Documentation — Offloader",
  description: "Run Offloader from first boot to production: concepts, quickstart, config and API reference, security, deployment, and ROI.",
  active: "docs",
  activeSlug: undefined,
  main: indexMain,
}));

console.log(`docs-site: rendered ${FLAT.length} pages + index → site/docs/`);
