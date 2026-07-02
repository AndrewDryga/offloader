# Creative Brief

Use this before designing. Keep it to one page unless the user asks for a full
strategy document.

## Inputs To Gather

- Audience: who is buying or evaluating, and what pressure are they under? (The
  owner of a production analytics API and the warehouse bill — data platform lead,
  staff data/infra engineer, FinOps-minded eng owner.)
- Job: what are they trying to do — serve repeated analytics reads without paying
  warehouse compute for each one, and without giving up governance?
- Category enemy: the bad alternative we replace — keep paying the warehouse, or
  build yet another ungoverned homegrown cache.
- Core claim: the one sentence the surface must make believable.
- Proof: product facts, the ROI before/after report, a serving-path diagram, an
  endpoint contract, freshness/`snapshot_id` in a response, the compiled-in tenant
  filter, measured latency and reducible spend, docs, architecture.
- Objections: why would a serious buyer hesitate? (Will it break prod? Is the
  isolation real? Is the data fresh enough? Can I defend the ROI to finance? Is
  native acceleration or a cache good enough already?)
- Conversion goal: book the fit call, share query history, read the diagnostic,
  compare against the alternatives, or understand the trust/isolation model.
- SEO intent: search query cluster and topic (where the surface is a page).
- Emotional target: calm authority, relief from a runaway bill, control,
  provable confidence — pick a specific feeling.
- Constraints: the security invariant, BYOC claim discipline, the 15–120 minute
  freshness window, bounded endpoints, accessibility, performance, and — for a
  page — server-rendered and crawlable.
- Forbidden cliches: layout, language, colors, illustrations, motion, or claims
  that would make this feel like a template or a generic data vendor.

## Output Shape

```
Audience:
Job:
Category enemy:
Core claim:
Proof:
Objections:
Conversion goal:
SEO intent:
Emotional target:
Constraints:
Forbidden cliches:
```

## Good Brief Smell

- Names the buyer's real fear.
- States what Offloader does that keeping the warehouse or a homegrown cache does
  not.
- Gives the designer proof to show, not just claims to decorate.
- Is honest where native acceleration or a cache is the better answer.
- Cuts at least one tempting but generic idea.
