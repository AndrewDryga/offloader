package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

const exampleDir = "../examples/customer-analytics"

func assertCode(t *testing.T, fs findings, code string) {
	t.Helper()
	if !slices.Contains(fs.codes(), code) {
		t.Fatalf("expected code %q in findings, got %v", code, fs.codes())
	}
}

func TestManifestAcceptsValid(t *testing.T) {
	fs := validateManifest(filepath.Join(exampleDir, "data/customer_usage/manifest.json"))
	if len(fs) != 0 {
		t.Fatalf("valid manifest had findings: %v", fs)
	}
}

func TestManifestRejectsBadManifest(t *testing.T) {
	fs := validateManifest(filepath.Join(exampleDir, "failure-lab/bad-manifest/manifest.json"))
	assertCode(t, fs, "invalid_snapshot_id")
	assertCode(t, fs, "duplicate_column")
	assertCode(t, fs, "unsupported_type")
	assertCode(t, fs, "missing") // producer
}

func TestManifestRejectsFieldsTheGatewayRequires(t *testing.T) {
	// The gateway requires partition_columns/sort_columns (referencing schema columns) and
	// non-empty created_at/watermark. This pre-check must reject what the container would,
	// or "run this before you ship" is a false promise.
	raw, _ := os.ReadFile(filepath.Join(exampleDir, "data/customer_usage/manifest.json"))
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	delete(m, "partition_columns")
	m["created_at"] = ""
	m["sort_columns"] = []string{"not_a_real_column"}
	m["files"] = []map[string]string{{"path": "gs://bucket/data.parquet", "format": "parquet"}}

	out := filepath.Join(t.TempDir(), "manifest.json")
	b, _ := json.Marshal(m)
	if err := os.WriteFile(out, b, 0o644); err != nil {
		t.Fatal(err)
	}

	fs := validateManifest(out)
	assertCode(t, fs, "missing")        // partition_columns absent + created_at empty
	assertCode(t, fs, "unknown_column") // sort_columns references a non-schema column
}

func TestManifestRejectsMissingFile(t *testing.T) {
	fs := validateManifest(filepath.Join(exampleDir, "failure-lab/missing-file/manifest.json"))
	assertCode(t, fs, "missing_file")
}

func TestManifestRejectsUnreadable(t *testing.T) {
	fs := validateManifest("/definitely/not/here.json")
	assertCode(t, fs, "missing_file")
}

func TestManifestCommandExitCodes(t *testing.T) {
	valid := filepath.Join(exampleDir, "data/customer_usage/manifest.json")
	bad := filepath.Join(exampleDir, "failure-lab/bad-manifest/manifest.json")

	if code := run([]string{"manifest", "validate", valid}, discard{}, discard{}); code != 0 {
		t.Fatalf("valid manifest exit = %d, want 0", code)
	}
	if code := run([]string{"manifest", "validate", bad}, discard{}, discard{}); code != 1 {
		t.Fatalf("bad manifest exit = %d, want 1", code)
	}
	if code := run([]string{"manifest"}, discard{}, discard{}); code != 2 {
		t.Fatalf("manifest with no subcommand exit = %d, want 2", code)
	}
}

// discard is an io.Writer that drops output (keeps test logs clean).
type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }
