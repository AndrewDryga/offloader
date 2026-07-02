---
name: art-director
description: Run an agency-grade art-direction pass for Offloader's public and customer-facing surfaces — creative territories, visual concept, layout grammar, type/color/motion system, and a rendered implementation loop that stays distinctive rather than template-generated. Use when designing or substantially changing positioning, the eventual portal marketing site, pilot collateral, diagrams, or the ROI report. Pairs with content-director for the words.
argument-hint: "<the surface to art-direct>"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, Agent
---

# Art Director

Own the visual concept, art direction, and rendered craft of Offloader's public
and customer-facing surfaces. Do not jump from "make it better" to code. First
fix the product story (with `content-director`), then explore creative
territories, choose one direction, define the art direction and visual system,
implement in small rendered passes, and review before landing.

**Scope and gating.** The `portal/` marketing site is gated behind the V1 proof
gates (see `context_and_goal.md`) — do not build it prematurely. Until it is
unlocked, the surfaces this skill directs are positioning docs, pilot collateral,
architecture diagrams, and the finance-grade ROI report. The craft is the same;
the medium is whatever surface is honestly in scope now.

## Coordinate The Hats

- Use `content-director` for the words, the argument, and the proof copy.
- Wear the **PM** hat (AGENTS.md) to protect the buyer, the job, and the smallest
  slice — is this surface even worth building right now?
- Wear the **Security** hat and run `/verify-api` before any visual asserts a
  capability. A serving-path diagram, a claimed isolation guarantee, or a
  benchmark must be true in the product and defensible from `context_and_goal.md`.
- Wear the **SEO**, **UX**, and **accessibility** hats: honest positioning, an
  obvious scan path, and — once the portal exists — titles/meta, structured data,
  and crawlable HTML.
- Use `/spec` then `/work` to plan and build, and `review-board` before landing
  anything material.

## Workflow

1. **Read the product and the surface.**
   Read `context_and_goal.md`, `docs/`, the README, existing layout and asset
   patterns, and the target surface. Treat the security invariant and the BYOC
   claim discipline as hard constraints.

2. **Write the creative brief.**
   Use `references/creative-brief.md`. Capture audience, conversion goal, category
   enemy, strongest proof, objections, emotional target, SEO intent (where the
   surface is a page), and forbidden cliches. If facts are missing, make the
   assumptions reversible and explicit.

3. **Generate creative territories.**
   Produce 3 to 5 meaningfully different directions before selecting one. Each
   territory names the core idea, the surface narrative, visual language,
   typography, color/material behavior, motion behavior, the product proof it
   leans on, an asset plan, SEO fit (if a page), risks, and implementation cost.

4. **Select one direction with reasons.**
   Score territories for product fit, memorability, trust, clarity, SEO fit,
   accessibility, performance, and implementation cost. Pick one. Do not average
   several directions into a bland compromise.

5. **Define the art direction.**
   Specify the layout grammar, grid, type scale, section rhythm, image/diagram/
   product treatment, icon/illustration style, interaction rules, and responsive
   behavior. Run `references/anti-template-rules.md` before accepting the direction.

6. **Implement in rendered passes.**
   Build one coherent surface or slice at a time. Prefer real product artifacts —
   the ROI before/after report, an endpoint contract, the
   manifest → snapshot → DuckDB → compiled plan → REST JSON diagram, the
   compiled-in tenant filter, freshness and `snapshot_id` in a response — over
   decorative filler. Keep any web surface server-rendered and crawlable. Use
   `references/implementation-loop.md`.

7. **Review and iterate.**
   Capture the rendered surface — screenshots for a page, the built document for a
   doc or report. Wear the **design-review** hat, fix the highest-severity issues,
   re-render, and repeat until it is no longer recognizably template-shaped and the
   UX / accessibility / performance floor is intact. Run `review-board` before merge
   when the diff is material.

## Non-Negotiables

- No generic SaaS hero, centered three-card feature grid, gradient-blob backdrop,
  fake dashboard, hero benchmark chart without methodology, vague trust badge,
  stock metaphor, or icon farm — unless the chosen direction makes it specific and
  defensible.
- Distinctive does not mean confusing. A data-platform buyer must understand the
  value and the trust/isolation model quickly.
- Visual drama must earn its cost. Motion, WebGL, canvas, video, and heavy images
  need a product reason, a reduced-motion path, and a performance check.
- Every visual claim must be true in the product and defensible from
  `context_and_goal.md` — no invented benchmarks, no "real-time" over a 15–120
  minute freshness window, no "data never leaves your cloud" unless the BYOC caveat
  holds.
- The final surface must work in its medium. Render the page in a browser; build
  the document. Code-only or draft-only review is not enough.

## Output

For planning work, produce:

```
Brief: <audience, goal, claim, proof, objections, SEO intent>
Territories: <3-5 options with scorecard>
Chosen direction: <why this one>
Art direction: <layout, type, color, imagery, motion, responsive rules>
Implementation plan: <small steps with verification>
Review loop: <what to render and the design-review checkpoints>
```

For implementation work, edit the relevant files, render the surface, capture it,
run the project gate (currently `make check && make doctor && coop tasks lint`;
see `context_and_goal.md`), and summarize the before/after.
