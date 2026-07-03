package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInferType(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{[]string{"1", "2", "3"}, "BIGINT"},
		{[]string{"0", "1"}, "BIGINT"}, // 0/1 are ints, not booleans
		{[]string{"1.5", "2"}, "DOUBLE"},
		{[]string{"true", "FALSE"}, "BOOLEAN"},
		{[]string{"2026-01-01"}, "DATE"},
		{[]string{"2026-01-01T10:00:00Z"}, "TIMESTAMP"},
		{[]string{"2026-01-01 10:00:00"}, "TIMESTAMP"},
		{[]string{"acct_a", "x"}, "VARCHAR"},
		{[]string{"1", "x"}, "VARCHAR"}, // mixed → widen to VARCHAR
		{[]string{}, "VARCHAR"},         // no samples → VARCHAR
	}
	for _, c := range cases {
		if got := inferType(c.in); got != c.want {
			t.Errorf("inferType(%v) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestScaffoldFromManifestReusesSchema(t *testing.T) {
	var out bytes.Buffer
	code := runScaffoldDataset(
		[]string{"--from", "../examples/customer-analytics/data/customer_usage/manifest.json", "--tenant-column", "tenant_id"},
		&out, io.Discard)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	for _, want := range []string{"id: customer_usage", "tenant_column: tenant_id", "usage_date, type: DATE", "api_calls, type: BIGINT"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output missing %q:\n%s", want, out.String())
		}
	}
}

func TestScaffoldFromCSVInfersColumnTypes(t *testing.T) {
	csv := "event_date,account_id,amount,items,is_paid,created_at\n" +
		"2026-01-01,acct_a,19.99,3,true,2026-01-01T10:00:00Z\n" +
		"2026-01-02,acct_b,5,1,false,2026-01-02T11:30:00Z\n"
	p := filepath.Join(t.TempDir(), "orders.csv")
	if err := os.WriteFile(p, []byte(csv), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if code := runScaffoldDataset([]string{"--from", p, "--id", "orders"}, &out, io.Discard); code != 0 {
		t.Fatalf("exit = %d", code)
	}
	for _, want := range []string{
		"id: orders", "event_date, type: DATE", "account_id, type: VARCHAR",
		"amount, type: DOUBLE", "items, type: BIGINT", "is_paid, type: BOOLEAN", "created_at, type: TIMESTAMP",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output missing %q:\n%s", want, out.String())
		}
	}
}

func TestScaffoldedDatasetDropsIntoAValidProject(t *testing.T) {
	dir := t.TempDir()
	proj := filepath.Join(dir, "p")
	if code := runInit([]string{"--out", proj, "--public"}, io.Discard, io.Discard); code != 0 {
		t.Fatal("init failed")
	}
	// A CSV whose columns match the scaffolded public endpoint's references.
	csv := "event_date,account_id,event_count\n2026-01-01,a,5\n"
	src := filepath.Join(dir, "e.csv")
	if err := os.WriteFile(src, []byte(csv), 0o644); err != nil {
		t.Fatal(err)
	}
	code := runScaffoldDataset(
		[]string{"--from", src, "--id", "events", "--out", filepath.Join(proj, "datasets", "events.yml")},
		io.Discard, io.Discard)
	if code != 0 {
		t.Fatalf("scaffold-dataset exit = %d", code)
	}
	if fs := validateProject(filepath.Join(proj, "offloader.yml")); len(fs) != 0 {
		t.Fatalf("project with the scaffolded dataset does not validate: %v", fs.codes())
	}
}
