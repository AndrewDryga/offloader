package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sampleRows() []queryRow {
	return []queryRow{
		{Fingerprint: "a", ExecPerMonth: 1000, AvgCostUSD: 1.0, Bounded: true, Endpoint: "e1"}, // 1000 reducible
		{Fingerprint: "b", ExecPerMonth: 500, AvgCostUSD: 2.0, Bounded: false, Endpoint: ""},   // 1000 excluded
	}
}

func TestComputeROISplitsReducibleFromExcluded(t *testing.T) {
	r := computeROI(sampleRows(), roiOpts{GatewayCostMonthly: 100, MigrationLabor: 1200})
	if r.TotalMonthlyCost != 2000 {
		t.Fatalf("total = %v, want 2000", r.TotalMonthlyCost)
	}
	if r.ReducibleMonthly != 1000 {
		t.Fatalf("reducible = %v, want 1000", r.ReducibleMonthly)
	}
	if r.ExcludedMonthly != 1000 {
		t.Fatalf("excluded = %v, want 1000", r.ExcludedMonthly)
	}
	// expected net = 1000*0.70 - 100 = 600
	if r.Expected != 600 {
		t.Fatalf("expected net = %v, want 600", r.Expected)
	}
	// payback = 1200 / 600 = 2 months
	if r.PaybackMonths != 2 {
		t.Fatalf("payback = %v, want 2", r.PaybackMonths)
	}
	if len(r.PerEndpoint) != 1 || r.PerEndpoint[0].Endpoint != "e1" {
		t.Fatalf("per-endpoint = %+v", r.PerEndpoint)
	}
}

func TestCommittedCapacityDropsConfidenceAndCaveats(t *testing.T) {
	r := computeROI(sampleRows(), roiOpts{CommittedCapacity: true})
	if !strings.Contains(strings.ToLower(r.Confidence), "committed") {
		t.Fatalf("confidence should reflect committed capacity, got %q", r.Confidence)
	}
	if !hasCaveat(r, "Committed") {
		t.Fatal("expected a committed-capacity caveat")
	}
}

func TestSharedWarehouseCaveat(t *testing.T) {
	if !hasCaveat(computeROI(sampleRows(), roiOpts{SharedWarehouse: true}), "Shared warehouse") {
		t.Fatal("expected a shared-warehouse caveat")
	}
}

func TestNoReducibleIsLevel1(t *testing.T) {
	rows := []queryRow{{ExecPerMonth: 100, AvgCostUSD: 1, Bounded: false}}
	r := computeROI(rows, roiOpts{})
	if !strings.Contains(r.Confidence, "Level 1") {
		t.Fatalf("no reducible spend should be Level 1, got %q", r.Confidence)
	}
}

func TestRenderIncludesRequiredSections(t *testing.T) {
	md := renderROI(computeROI(sampleRows(), roiOpts{}))
	for _, s := range []string{"Confidence", "Assumptions", "Net monthly savings",
		"Per-endpoint mapping", "caveats", "Conservative", "Expected", "Aggressive", "migration labor"} {
		if !strings.Contains(md, s) {
			t.Errorf("report missing section/term %q", s)
		}
	}
}

func TestROICommandReadsSampleCSV(t *testing.T) {
	sample := "../examples/roi/sample-query-history.csv"
	out := filepath.Join(t.TempDir(), "roi.md")
	code := run([]string{"roi", "report", "--input", sample, "--out", out}, discard{}, discard{})
	if code != 0 {
		t.Fatalf("roi report exit = %d, want 0", code)
	}
	body, _ := os.ReadFile(out)
	if !strings.Contains(string(body), "customer_usage_summary") {
		t.Error("report should map the sample's candidate endpoints")
	}
}

func hasCaveat(r roiReport, substr string) bool {
	for _, c := range r.Caveats {
		if strings.Contains(c, substr) {
			return true
		}
	}
	return false
}
