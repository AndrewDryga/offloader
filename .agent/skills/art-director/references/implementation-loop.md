# Implementation Loop

Use this once a creative direction is selected. Offloader has two surface media —
a **document** (docs, pilot collateral, the ROI report) today, and a **web page**
(the `portal/` marketing site) once the V1 proof gates unlock it. Build in small
rendered passes for whichever is in scope.

## When The Surface Is A Document

Build order:

1. Structure the argument first: the claim, the proof, the mechanism, the
   comparison, the objections, the next step.
2. Add the proof — tables, numbers, and the serving-path diagram — before any
   decorative element.
3. Add the summary and CTA only after the argument is clear.

Rendering checks:

- The built document (Markdown preview, PDF, or generated report) actually
  renders.
- Tables and numbers are legible; the ROI figures reconcile.
- Diagrams match the real serving path and claim nothing the product can't do.
- No broken links, dead anchors, stale claims, or placeholder text.

Verification:

- Run the project gate (currently `make check && make doctor && coop tasks lint`).
- When a `docs-check` component gate lands, run it for document surfaces.

## When The Surface Is A Web Page (portal)

Build order:

1. Establish page-level tokens: color variables, type scale, spacing rhythm,
   section constraints, image treatment, and motion preferences.
2. Build the first viewport and navigation. Verify the product and category are
   obvious without scrolling.
3. Build proof/mechanism sections before decorative sections.
4. Add CTA and trust/FAQ sections only after the narrative is clear.
5. Add motion and interaction last, with `prefers-reduced-motion`.

Rendering checks — capture screenshots at minimum:

- Desktop wide: 1440 x 1000
- Desktop narrow: 1024 x 900
- Mobile: 390 x 844
- Short viewport: 1440 x 700

Check:

- Text does not overlap, truncate badly, or resize layout unexpectedly.
- The first viewport hints at the next section.
- The primary CTA stays visible or quickly discoverable.
- Product-specific visuals load and are legible.
- Mobile layout is designed, not merely stacked.
- Hover/focus states are visible and stable.
- Motion does not hide content or create layout shift.

Verification:

- Run the project gate (currently `make check && make doctor && coop tasks lint`)
  plus any `gateway-check` / component gate the touched code requires.
- Use browser screenshots before calling the page done.
- Check the initial HTML contains real content for crawlers.
- Check title/meta/canonical/schema/internal links where the page requires them.
- Check image dimensions, alt text, contrast, keyboard focus, reduced motion, and
  no horizontal overflow.

## Review Loop

After the first complete render:

1. Wear the **design-review** hat against the rendered surface.
2. Fix blockers and majors first.
3. Re-render the same surface (same viewport set for a page; rebuild the document).
4. Review again if visual structure, copy, or interaction changed.
5. Run `review-board` before merge when the diff is material.
