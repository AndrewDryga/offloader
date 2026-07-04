# Diagnostic & Offload Pilot — Statement of Work (template)

> **This is a reusable template, not a signed agreement and not legal advice.** Fill every
> `[bracketed]` field per engagement and have counsel review before signing. **Do not commit a
> filled copy** (real client names, personal identifiers, `РНОКПП`, home address, or negotiated
> figures) to this public repository — keep executed SOWs off-repo.

The commercial terms here mirror, and must stay consistent with, the public offer
([pricing on the site](../site/index.html) and [the ROI calculator](../site/roi.html)). If you
change the model in one place, change it in all of them.

---

## 1. Parties

- **Provider:** Andrii Dryga, an individual entrepreneur (ФОП / *fizychna osoba-pidpryiemets*)
  registered in Ukraine, `РНОКПП [•]`, registered address `[•]`, trading as **Offloader**
  (`[contact email]`). *(A Ukrainian ФОП is the individual, not a separate limited-liability
  entity; the individual is the contracting party. See §8 for how liability is handled.)*
- **Client:** `[legal entity name]`, `[entity type / jurisdiction]`, `[registered address]`
  (`[Client contact]`).

Effective date: `[•]`.

## 2. Background

Offloader is self-hosted software that offloads repeated, product-facing analytics **reads** from
the Client's data warehouse (Snowflake, BigQuery, Databricks, Redshift, …) to pre-computed
snapshots served from the Client's **own** infrastructure. This SOW covers a paid **Diagnostic**
and, if the Client elects to proceed, an **Offload Pilot**. Offloader runs entirely inside the
Client's environment; the Provider operates no hosted service and does not receive the Client's
production data (see §6).

## 3. Phase 1 — Diagnostic (fixed fee)

- **Objective.** Measure the Client's *reducible* warehouse spend on the in-scope endpoints and
  agree a **baseline** for the pilot.
- **Deliverable.** A written diagnostic: the measured/estimated monthly saving, the agreed
  baseline expressed as a **rate per million requests**, a fit assessment (an honest "not a fit"
  is a valid outcome), and a recommended **shadow → canary → cutover** plan.
- **Timeline.** `[N — recommended: 10]` business days from the Client granting access.
- **Fee.** Fixed **`[$• — recommended: $5,000]`**, invoiced `[on signing / on delivery]`.
- **Credit.** If the Client proceeds to the Pilot within `[30]` days of delivery, the Diagnostic
  fee is **credited** against the first reconciliation. *(Recommended — lowers buyer risk.)*
- **Optional risk-reversal.** *[If elected:]* if the Diagnostic does not identify at least
  **`[$•/mo — e.g. $1,500]`** of reducible spend, the Diagnostic fee is refunded. *(Safely
  beatable — the reference cutover found ~$2,560/mo at a single customer.)*
- **Client responsibilities.** Read access to the relevant warehouse cost/usage data, a
  representative sample of the endpoints and query shapes to offload, and a named point of contact.

## 4. Phase 2 — Offload Pilot (share of savings)

The pilot fee is a **share of the savings Offloader actually produces**, on these terms — quoted
verbatim from the public offer so there is no daylight between the site and the contract:

- The **baseline is set once**, in the Diagnostic, as a rate per million requests, agreed before
  the Client commits — so the Provider **never re-audits the warehouse bill**; the Client's own
  request count does the math.
- The fee is **20% of the measured saving, reconciled quarterly, net of what Offloader costs to
  run** on the Client's own infrastructure. The Client keeps the other 80%.
- **No saving, no fee.** There is no per-request meter.
- For a **reserved-capacity / committed** warehouse tier, the fee applies **only once the Client
  actually downsizes the committed tier**. Moving query volume off it does not, by itself, lower a
  committed bill, and it will not be billed as a saving.

**Term.** Initial `[N]` months, then month-to-month; either party may terminate on `[30]` days'
notice. **No lock-in:** Offloader is self-hosted; on termination the Client keeps its container,
config, snapshots, and data, and the warehouse/app are exactly as before.

**What the Provider delivers in the Pilot.** Endpoint configuration for the in-scope datasets,
cutover support (response-parity validation → canary → cutover), and support that is a **response-time
commitment, not an uptime SLA** — the Client operates the software, so availability is the
Client's.

## 5. Software license

Offloader is provided under the **Functional Source License 1.1 (FSL-1.1-ALv2)** (see
[`LICENSE`](../LICENSE)); each release converts to **Apache-2.0 two years after it ships**. This
SOW grants no rights in the software beyond that license.

## 6. Data & security

The Client **self-hosts**. Snapshots, request traffic, and any tenant data stay within the
Client's own environment; the Provider does not host, receive, or process the Client's production
or end-user data in the course of the Pilot, except for cost/usage information the Client
deliberately shares for the Diagnostic. Credentials the Client provides are used only for the
agreed work and are never stored in the software's logs, error bodies, or support bundles (they
are scrubbed/redacted). See [the security model](../docs/security-model.md).

## 7. Fees, invoicing & taxes

Currency `[USD]`; invoices payable within `[N]` days via `[Wise / bank transfer]`. Fees are
exclusive of any taxes; the Client is responsible for any withholding required by its
jurisdiction. The Provider will supply a **W-8BEN** (or local tax-residency certificate) on
request. On request, the Provider will issue a **certificate of insurance** (see §8) naming the
Client.

## 8. Limitation of liability *(negotiable — default below)*

The Provider maintains **professional indemnity (errors & omissions) insurance of not less than
`$1,000,000` per claim**, valid **worldwide including the US and Canada**, and will provide a
certificate of insurance on request.

Except for liability that cannot be limited by law (including fraud, willful misconduct, and
death or personal injury), and subject to that insurance:

- Neither party is liable for indirect, incidental, special, or consequential damages, or for lost
  profits or lost revenue.
- The Provider's **total aggregate liability** under this SOW is capped at the **greater of** (a)
  the fees the Client paid under this SOW in the `[12]` months before the claim, or (b) the
  proceeds actually recovered under the Provider's professional indemnity insurance for that claim.

*(This caps the Provider's personal exposure — a ФОП has no corporate liability shield — while
still giving the Client recourse up to the insured amount for a covered claim.)*

## 9. Confidentiality

Each party protects the other's confidential information and uses it only for this engagement,
`[per the parties' mutual NDA dated [•] / per the mutual terms in this §9]`. The Client's data and
the Provider's non-public materials are each confidential.

## 10. Intellectual property

The Client owns its data, snapshots, and configuration. The Provider retains all intellectual
property in Offloader and in any generally-applicable improvements. Feedback the Client provides
may be used by the Provider without restriction.

## 11. Warranties & disclaimer

The Provider will perform the services in a professional and workmanlike manner. The **software**
is provided under the FSL "AS IS" disclaimer (§5). Apart from any risk-reversal expressly elected
in §3, the Provider does **not** warrant that savings will reach any particular figure.

## 12. General

Governing law: `[•]`. Dispute resolution: `[•]`. Neither party may assign without the other's
consent, except to a successor of substantially all its business. This SOW (with any referenced
NDA and the FSL) is the entire agreement on its subject matter; if it conflicts with the FSL on
the software license, the FSL governs the license.

---

**Provider** — Andrii Dryga (ФОП)  ·  signature `[•]`  ·  date `[•]`

**Client** — `[name, title]`  ·  signature `[•]`  ·  date `[•]`
