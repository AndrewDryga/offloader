# Tone Rules

Load this reference when polishing important copy, rewriting a surface that sounds
generated, or reviewing copy before it ships.

## Voice

Offloader should sound:

- technically literate, not academic
- confident, not inflated
- direct, not blunt for sport
- specific, not busy
- commercial, not salesy
- calm about cost and security, not theatrical

The reader is a skeptical data-platform or infrastructure owner. They have seen
vendors promise magic cost savings and hand-wave the governance and the ROI.
Respect that.

## Words To Distrust

Not banned in every context, but usually evidence that the sentence is avoiding
the real claim:

- unlock
- unleash
- empower
- supercharge
- blazing-fast / lightning-fast
- 10x / next-generation / best-in-class
- real-time (when the truth is 15–120 minute freshness)
- infinite / limitless scale
- zero-copy (unless it literally is)
- seamless
- robust
- cutting-edge
- game-changing
- single source of truth
- comprehensive solution
- streamline your workflow
- leverage the power of

When one appears, replace it with the mechanism, consequence, or proof.

## Rewrite Patterns

Bad:

> Unlock blazing-fast analytics with a powerful platform that supercharges your
> data stack and helps teams move faster with confidence.

Good:

> Serve your most-repeated analytics endpoints from local DuckDB over approved
> snapshots, so the warehouse stops billing for the same read a thousand times a
> day.

Bad:

> Our robust security model ensures your data is always safe and compliant.

Good:

> Each API key reaches only the endpoints granted to it, for the tenants bound to
> it, selecting only allowed columns — the tenant filter is compiled into the
> query and the caller can't override it.

Bad:

> Real-time insights at infinite scale.

Good:

> Endpoints serve from snapshots refreshed on a 15–120 minute cadence, and every
> response carries its `snapshot_id` and freshness so callers know exactly how
> current the data is.

Bad:

> A single source of truth for your data operations.

Good:

> A before/after report shows what each offloaded endpoint used to cost in
> warehouse spend, what it costs now, and the measured latency and freshness — so
> finance can check the savings.

## Sentence Rules

- Put the concrete noun before the abstraction.
- Prefer active verbs: serves, compiles, enforces, refreshes, preserves, reports.
- Use short sentences for real emphasis, not as a style tic.
- Keep one hard idea per sentence.
- Remove throat-clearing openers: "With Offloader,", "By leveraging", "In order to".
- Do not stack modifiers: "fast, scalable, seamless, enterprise-grade".
- If a paragraph has three claims, at least one needs proof.

## Headline Rules

Strong headlines do one job:

- name the category problem
- state the product mechanism
- make a sharp comparison
- answer a real question
- surface a proof point

Weak headlines sound interchangeable:

- "Built for modern data teams"
- "Query faster"
- "Blazing-fast analytics"
- "Everything your data stack needs"
- "Powerful and scalable"

Prefer:

- "Stop paying warehouse compute for the same analytics read."
- "Governed REST endpoints over approved snapshots — not raw SQL."
- "The compiler inserts the tenant filter. The caller can't remove it."
- "Prove the savings before you commit: a finance-grade before/after report."

## SEO Without Mush

Use the search phrase only where it reads naturally. A high-ranking page still
needs a clear argument, useful headings, and answers to real questions.

Good SEO copy:

- answers the query quickly
- names the alternative the buyer is weighing (the warehouse, a homegrown cache,
  native acceleration)
- includes concrete subtopics crawlers can understand
- links to related proof with descriptive anchors
- uses FAQs for actual objections, not keyword padding

Bad SEO copy:

- repeats the same phrase in every heading
- uses broad noun piles like "real-time data analytics acceleration platform"
- hides the answer below a brand story
- adds generic FAQs no serious buyer would ask

## Final Pass

Cut:

- any sentence that only praises the product
- any adjective not backed by proof
- any section that repeats a previous section's job
- any CTA that asks for commitment before trust is earned

Keep:

- mechanisms
- examples
- comparisons
- objections
- receipts (the ROI report, the freshness metadata, the audit)
- plain English
