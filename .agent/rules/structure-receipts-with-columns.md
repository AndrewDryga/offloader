# Structure receipt-like layouts with columns

**Rule:** Any public-facing receipt, ledger, or invoice visual that mixes labels, values, and
annotations must use structured rows and CSS columns. Do not align those pieces with literal
spaces inside one `pre` when any part can change width, animate, or receive inline styling.

**Why:** (A.D., 2026-07-09) The homepage hero ledger used a hand-spaced `pre` while the request
count and bill animated to their final values. The right-side notes drifted out of column
alignment once the values changed width.

**How to apply:**
- Use semantic row markup with separate label, value, and note elements.
- Reserve final numeric widths with tabular figures when values animate.
- Verify with a rendered screenshot, not just by reading the HTML.
