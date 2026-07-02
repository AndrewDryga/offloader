# Anti-Template Rules

Use this when generating creative territories, reviewing art direction, and
accepting implementation.

## Hard Rejects

- Split hero with left text and right generic illustration.
- Centered headline followed by three feature cards with icons.
- Purple/blue gradient blob, bokeh orb, abstract mesh, or decorative data-glow as
  the primary visual idea.
- Hero benchmark chart or "10x faster" bar with no methodology behind it.
- Fake dashboard or generic pipeline node-graph that does not teach the actual
  serving mechanism.
- Generic phrases as art: "blazing-fast analytics", "real-time at scale",
  "all-in-one data platform", "built for data teams", "enterprise-grade security"
  without concrete proof.
- Random isometric servers, shields, robots, warehouses, or circuit patterns.
- One-note palette where every element is the same hue family.
- Motion that only reveals boxes on scroll.

## Strong Replacements

- Show the mechanism: manifest → validated snapshot → DuckDB local table →
  compiled endpoint plan → REST JSON response.
- Build around a proprietary artifact: the ROI before/after report, an endpoint
  contract, a response carrying `snapshot_id` and freshness, the compiled-in
  tenant filter, the previous-good-snapshot-preserved-on-failure behavior.
- Use editorial composition: strong type hierarchy, asymmetric rhythm, meaningful
  whitespace, proof integrated into the layout.
- Use product-specific diagrams or real artifacts instead of decorative art.
- Use comparison as visual structure: a raw warehouse read billed every time vs a
  governed offloaded endpoint; an ungoverned homegrown cache vs a contracted
  endpoint with tenant and column enforcement.
- Let one distinctive visual device carry the surface, then keep the rest
  restrained.

## Distinctive But Usable

- The first viewport must say what Offloader is and why it matters to a data buyer.
- Navigation, CTA, and the scan path must stay obvious.
- Fancy interactions must have static meaning when motion is disabled.
- Dense technical proof is allowed when hierarchy makes it scannable.
- Buyer trust — the isolation model, the honest freshness window, the provable
  ROI — beats spectacle.

## Territory Test

Ask:

1. Could this exact surface sell five unrelated data vendors if the logo changed?
2. Does the first viewport contain product-specific proof or mechanism?
3. Is the art direction a real idea, or just styling?
4. Would a skeptical data-platform or security buyer trust it after reading the
   claims?
5. Can it be implemented well within the current repo and its gates?

If answer 1 is yes or answer 2 is no, reject the direction.
