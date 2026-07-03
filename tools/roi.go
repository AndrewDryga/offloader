package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

func init() {
	register(command{
		name:    "roi",
		summary: "roi subcommands: `roi report --input query-history.csv` (finance-grade savings report)",
		run:     runROI,
	})
}

func runROI(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 || args[0] != "report" {
		fmt.Fprintln(stderr, "usage: offloader roi report --input FILE [--gateway-cost N] [--migration-labor N] [--committed-capacity] [--shared-warehouse] [--out FILE]")
		return 2
	}
	fs := flag.NewFlagSet("roi report", flag.ContinueOnError)
	fs.SetOutput(stderr)
	input := fs.String("input", "", "query-history CSV (see docs/roi.md)")
	out := fs.String("out", "", "write the markdown report here (default: stdout)")
	opts := roiOpts{}
	fs.Float64Var(&opts.GatewayCostMonthly, "gateway-cost", 800, "estimated Offloader infra cost per month (USD)")
	fs.Float64Var(&opts.MigrationLabor, "migration-labor", 20000, "one-time pilot/migration labor (USD)")
	fs.BoolVar(&opts.CommittedCapacity, "committed-capacity", false, "the warehouse is on committed/flat-rate capacity")
	fs.BoolVar(&opts.SharedWarehouse, "shared-warehouse", false, "the warehouse is shared with other workloads")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if *input == "" {
		fmt.Fprintln(stderr, "roi report: --input is required")
		return 2
	}

	rows, err := readQueryHistory(*input)
	if err != nil {
		fmt.Fprintln(stderr, "roi report: "+err.Error())
		return 1
	}
	report := computeROI(rows, opts)
	md := renderROI(report)

	if *out == "" {
		fmt.Fprint(stdout, md)
	} else if err := os.WriteFile(*out, []byte(md), 0o644); err != nil {
		fmt.Fprintln(stderr, "roi report: "+err.Error())
		return 1
	} else {
		fmt.Fprintf(stdout, "wrote %s (confidence %s)\n", *out, report.Confidence)
	}
	return 0
}

type queryRow struct {
	Fingerprint  string
	ExecPerMonth float64
	AvgCostUSD   float64
	Warehouse    string
	Bounded      bool
	Endpoint     string
}

type roiOpts struct {
	GatewayCostMonthly float64
	MigrationLabor     float64
	CommittedCapacity  bool
	SharedWarehouse    bool
}

type endpointLine struct {
	Endpoint       string
	ExecPerMonth   float64
	MonthlyCostUSD float64
}

type roiReport struct {
	Opts             roiOpts
	TotalMonthlyCost float64
	ReducibleMonthly float64
	ExcludedMonthly  float64
	PerEndpoint      []endpointLine
	Conservative     float64 // net monthly savings
	Expected         float64
	Aggressive       float64
	PaybackMonths    float64
	Confidence       string
	Caveats          []string
}

// Reduction factors: fraction of the reducible warehouse spend that offloading
// actually removes, under conservative / expected / aggressive assumptions.
var reductionFactors = struct{ Conservative, Expected, Aggressive float64 }{0.40, 0.70, 0.90}

func computeROI(rows []queryRow, opts roiOpts) roiReport {
	r := roiReport{Opts: opts}
	byEndpoint := map[string]*endpointLine{}

	for _, q := range rows {
		monthly := q.ExecPerMonth * q.AvgCostUSD
		r.TotalMonthlyCost += monthly
		// Reducible = a bounded query mapped to a serving endpoint.
		if q.Bounded && q.Endpoint != "" {
			r.ReducibleMonthly += monthly
			e := byEndpoint[q.Endpoint]
			if e == nil {
				e = &endpointLine{Endpoint: q.Endpoint}
				byEndpoint[q.Endpoint] = e
			}
			e.ExecPerMonth += q.ExecPerMonth
			e.MonthlyCostUSD += monthly
		} else {
			r.ExcludedMonthly += monthly
		}
	}

	for _, e := range byEndpoint {
		r.PerEndpoint = append(r.PerEndpoint, *e)
	}
	sort.Slice(r.PerEndpoint, func(i, j int) bool { return r.PerEndpoint[i].MonthlyCostUSD > r.PerEndpoint[j].MonthlyCostUSD })

	r.Conservative = r.ReducibleMonthly*reductionFactors.Conservative - opts.GatewayCostMonthly
	r.Expected = r.ReducibleMonthly*reductionFactors.Expected - opts.GatewayCostMonthly
	r.Aggressive = r.ReducibleMonthly*reductionFactors.Aggressive - opts.GatewayCostMonthly

	if r.Expected > 0 {
		r.PaybackMonths = opts.MigrationLabor / r.Expected
	}

	r.Confidence, r.Caveats = assess(r)
	return r
}

// claim more than the inputs support: query logs justify Level 2 at most; Level 3/4
// require warehouse-capacity reduction and finance verification we cannot see here.
func assess(r roiReport) (string, []string) {
	var caveats []string
	level := "Level 2 (query logs + cost allocation estimate reducible spend)"

	if r.ReducibleMonthly == 0 {
		level = "Level 1 (technical candidate only; no dollar claim)"
		caveats = append(caveats, "No bounded, endpoint-mapped queries found — nothing reducible in this input.")
	}
	if r.Opts.CommittedCapacity {
		level = "Level 1–2 (committed capacity — per-query savings may NOT reduce the bill)"
		caveats = append(caveats,
			"Committed/flat-rate capacity: removing query volume does not lower the bill until the committed tier or cluster size is actually reduced (that is Level 3). Do not promise bill reduction.")
	}
	if r.Opts.SharedWarehouse {
		caveats = append(caveats,
			"Shared warehouse: this workload is not the only cost driver, so attributing savings to it is an estimate — validate against per-query/warehouse cost allocation.")
	}
	caveats = append(caveats,
		"Level 3 (reduce warehouse size/schedule/capacity) and Level 4 (finance verifies the bill dropped) require a live before/after measurement after offload.")
	return level, caveats
}

func readQueryHistory(path string) ([]queryRow, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	rd := csv.NewReader(f)
	records, err := rd.ReadAll()
	if err != nil {
		return nil, err
	}
	if len(records) < 2 {
		return nil, fmt.Errorf("input has no data rows")
	}
	idx := headerIndex(records[0])
	need := []string{"fingerprint", "executions_per_month", "avg_cost_usd", "bounded", "candidate_endpoint"}
	for _, n := range need {
		if _, ok := idx[n]; !ok {
			return nil, fmt.Errorf("missing required column %q (see docs/roi.md)", n)
		}
	}

	var out []queryRow
	for i, rec := range records[1:] {
		exec, err1 := strconv.ParseFloat(get(rec, idx, "executions_per_month"), 64)
		cost, err2 := strconv.ParseFloat(get(rec, idx, "avg_cost_usd"), 64)
		if err1 != nil || err2 != nil {
			return nil, fmt.Errorf("row %d: non-numeric executions_per_month/avg_cost_usd", i+2)
		}
		out = append(out, queryRow{
			Fingerprint:  get(rec, idx, "fingerprint"),
			ExecPerMonth: exec,
			AvgCostUSD:   cost,
			Warehouse:    get(rec, idx, "warehouse"),
			Bounded:      strings.EqualFold(get(rec, idx, "bounded"), "true"),
			Endpoint:     get(rec, idx, "candidate_endpoint"),
		})
	}
	return out, nil
}

func headerIndex(header []string) map[string]int {
	idx := map[string]int{}
	for i, h := range header {
		idx[strings.TrimSpace(strings.ToLower(h))] = i
	}
	return idx
}

func get(rec []string, idx map[string]int, col string) string {
	if i, ok := idx[col]; ok && i < len(rec) {
		return strings.TrimSpace(rec[i])
	}
	return ""
}

func renderROI(r roiReport) string {
	var b strings.Builder
	usd := func(v float64) string { return fmt.Sprintf("$%.0f", v) }

	fmt.Fprintln(&b, "# Offloader ROI diagnostic")
	fmt.Fprintln(&b)
	fmt.Fprintf(&b, "**Confidence:** %s\n\n", r.Confidence)
	fmt.Fprintf(&b, "Total analyzed warehouse spend: **%s/mo**. Reducible (bounded + endpoint-mapped): **%s/mo**. Excluded (unbounded or unmapped): %s/mo.\n\n",
		usd(r.TotalMonthlyCost), usd(r.ReducibleMonthly), usd(r.ExcludedMonthly))

	fmt.Fprintln(&b, "## Assumptions")
	fmt.Fprintf(&b, "- Reduction of reducible spend: conservative %.0f%%, expected %.0f%%, aggressive %.0f%%.\n",
		reductionFactors.Conservative*100, reductionFactors.Expected*100, reductionFactors.Aggressive*100)
	fmt.Fprintf(&b, "- Offloader infra: %s/mo. One-time migration labor: %s.\n\n", usd(r.Opts.GatewayCostMonthly), usd(r.Opts.MigrationLabor))

	if r.Opts.CommittedCapacity {
		// Committed/flat-rate capacity: query-volume reduction does NOT lower the bill until
		// the tier/cluster is actually resized. Presenting these as realized "net savings"
		// (with a payback) is the exact bill-reduction promise docs/roi.md forbids — so they
		// are labeled as unrealized potential and the payback line is withheld.
		fmt.Fprintln(&b, "## Potential monthly savings — NOT yet realized (committed capacity)")
		fmt.Fprintln(&b, "> Committed/flat-rate capacity: these become real only after you reduce the committed tier or cluster size (Level 3). They are not a bill reduction today; there is no payback until capacity is cut.")
		fmt.Fprintln(&b, "| Scenario | Potential/mo | Annualized |")
	} else {
		fmt.Fprintln(&b, "## Net monthly savings (after Offloader cost)")
		fmt.Fprintln(&b, "| Scenario | Net savings/mo | Annualized |")
	}
	fmt.Fprintln(&b, "| --- | ---: | ---: |")
	fmt.Fprintf(&b, "| Conservative | %s | %s |\n", usd(r.Conservative), usd(r.Conservative*12))
	fmt.Fprintf(&b, "| Expected | %s | %s |\n", usd(r.Expected), usd(r.Expected*12))
	fmt.Fprintf(&b, "| Aggressive | %s | %s |\n\n", usd(r.Aggressive), usd(r.Aggressive*12))
	if r.PaybackMonths > 0 && !r.Opts.CommittedCapacity {
		fmt.Fprintf(&b, "Payback on migration labor (expected): **%.1f months**.\n\n", r.PaybackMonths)
	}

	fmt.Fprintln(&b, "## Per-endpoint mapping")
	if len(r.PerEndpoint) == 0 {
		fmt.Fprintln(&b, "_No reducible, endpoint-mapped queries in this input._")
	} else {
		fmt.Fprintln(&b, "| Candidate endpoint | Executions/mo | Warehouse cost/mo |")
		fmt.Fprintln(&b, "| --- | ---: | ---: |")
		for _, e := range r.PerEndpoint {
			fmt.Fprintf(&b, "| %s | %.0f | %s |\n", e.Endpoint, e.ExecPerMonth, usd(e.MonthlyCostUSD))
		}
	}
	fmt.Fprintln(&b)

	fmt.Fprintln(&b, "## Exclusions and caveats")
	for _, c := range r.Caveats {
		fmt.Fprintf(&b, "- %s\n", c)
	}
	return b.String()
}
