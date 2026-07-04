package main

import (
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func init() {
	register(command{
		name:    "scaffold-dataset",
		summary: "draft a datasets/*.yml schema from a manifest.json (reuse) or a .csv (infer types)",
		run:     runScaffoldDataset,
	})
}

func runScaffoldDataset(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("scaffold-dataset", flag.ContinueOnError)
	fs.SetOutput(stderr)
	from := fs.String("from", "", "a manifest.json (reuse its schema) or a .csv (infer column types)")
	id := fs.String("id", "", "dataset id (default: derived from the file/dir name)")
	tenantCol := fs.String("tenant-column", "", "mark a column as the tenant column (multi-tenant datasets)")
	out := fs.String("out", "", "write to this file (default: stdout)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *from == "" {
		fmt.Fprintln(stderr, "usage: offloader scaffold-dataset --from <manifest.json|data.csv> [--id NAME] [--tenant-column COL] [--out FILE]")
		return 2
	}

	cols, manifestPointer, provenance, err := readSchemaFrom(*from)
	if err != nil {
		fmt.Fprintln(stderr, "scaffold-dataset: "+err.Error())
		return 1
	}
	if len(cols) == 0 {
		fmt.Fprintln(stderr, "scaffold-dataset: found no columns to scaffold")
		return 1
	}

	dsID := *id
	if dsID == "" {
		dsID = deriveDatasetID(*from)
	}
	if !safeIdent(dsID) {
		fmt.Fprintf(stderr, "scaffold-dataset: dataset id %q is not a safe identifier — pass a valid --id\n", dsID)
		return 1
	}

	if *tenantCol != "" && !hasColumn(cols, *tenantCol) {
		fmt.Fprintf(stderr, "scaffold-dataset: --tenant-column %q is not one of the columns\n", *tenantCol)
		return 1
	}
	for _, c := range cols {
		if !safeColumn(c.Name) {
			fmt.Fprintf(stderr, "scaffold-dataset: warning: column %q is not a safe identifier — rename it in your data, or the gateway will reject it\n", c.Name)
		}
	}

	yaml := renderDataset(dsID, cols, *tenantCol, manifestPointer, provenance)

	if *out == "" {
		fmt.Fprint(stdout, yaml)
		return 0
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		fmt.Fprintln(stderr, "scaffold-dataset: "+err.Error())
		return 1
	}
	if err := os.WriteFile(*out, []byte(yaml), 0o644); err != nil {
		fmt.Fprintln(stderr, "scaffold-dataset: "+err.Error())
		return 1
	}
	fmt.Fprintf(stdout, "wrote %s (%d columns, %s)\n", *out, len(cols), provenance)
	return 0
}

// readSchemaFrom returns the columns, a `manifest:` pointer for the dataset, and a short
// provenance note. A .json is a manifest (reuse its authoritative schema) or a bare
// [{name,type}] array; a .csv has its column types inferred from the header + sample rows.
func readSchemaFrom(path string) (cols []columnYML, manifestPointer, provenance string, err error) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".csv":
		cols, err = inferCSVSchema(path)
		return cols, "data/<dataset>/manifest.json", "types inferred from CSV — review them", err

	case ".json":
		b, e := os.ReadFile(path)
		if e != nil {
			return nil, "", "", e
		}
		var m manifestJSON
		if json.Unmarshal(b, &m); len(m.Schema) > 0 {
			return m.Schema, path, "schema from manifest", nil
		}
		var arr []columnYML
		if json.Unmarshal(b, &arr); len(arr) > 0 {
			return arr, "data/<dataset>/manifest.json", "schema from JSON", nil
		}
		return nil, "", "", fmt.Errorf("%s has no `schema` array and is not a [{name,type}] list", filepath.Base(path))

	default:
		return nil, "", "", fmt.Errorf("unsupported input %q — use a .json manifest or a .csv", filepath.Base(path))
	}
}

func inferCSVSchema(path string) ([]columnYML, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1 // tolerate ragged rows rather than erroring
	header, err := r.Read()
	if err != nil {
		return nil, fmt.Errorf("cannot read CSV header: %w", err)
	}

	samples := make([][]string, len(header))
	for read := 0; read < 1000; read++ {
		row, err := r.Read()
		if err != nil {
			break
		}
		for i := range header {
			if i < len(row) && strings.TrimSpace(row[i]) != "" {
				samples[i] = append(samples[i], strings.TrimSpace(row[i]))
			}
		}
	}

	cols := make([]columnYML, len(header))
	for i, name := range header {
		cols[i] = columnYML{Name: strings.TrimSpace(name), Type: inferType(samples[i])}
	}
	return cols, nil
}

// inferType picks the narrowest supported DuckDB type ALL non-empty samples satisfy,
// falling back to VARCHAR. Order matters: integers also parse as floats, and 0/1 are
// integers not booleans.
func inferType(samples []string) string {
	if len(samples) == 0 {
		return "VARCHAR"
	}
	all := func(pred func(string) bool) bool {
		for _, s := range samples {
			if !pred(s) {
				return false
			}
		}
		return true
	}
	switch {
	case all(isBoolLiteral):
		return "BOOLEAN"
	case all(isInt):
		return "BIGINT"
	case all(isFloat):
		return "DOUBLE"
	case all(isDate):
		return "DATE"
	case all(isTimestamp):
		return "TIMESTAMP"
	default:
		return "VARCHAR"
	}
}

func isBoolLiteral(s string) bool {
	switch strings.ToLower(s) {
	case "true", "false":
		return true
	}
	return false
}

func isInt(s string) bool { _, err := strconv.ParseInt(s, 10, 64); return err == nil }
func isFloat(s string) bool {
	_, err := strconv.ParseFloat(s, 64)
	return err == nil
}
func isDate(s string) bool { _, err := time.Parse("2006-01-02", s); return err == nil }
func isTimestamp(s string) bool {
	for _, layout := range []string{time.RFC3339, "2006-01-02 15:04:05", "2006-01-02T15:04:05"} {
		if _, err := time.Parse(layout, s); err == nil {
			return true
		}
	}
	return false
}

func hasColumn(cols []columnYML, name string) bool {
	for _, c := range cols {
		if c.Name == name {
			return true
		}
	}
	return false
}

func deriveDatasetID(path string) string {
	base := filepath.Base(path)
	if strings.EqualFold(base, "manifest.json") {
		// .../data/<dataset>/manifest.json → the parent dir is the dataset name.
		base = filepath.Base(filepath.Dir(path))
	} else {
		base = strings.TrimSuffix(base, filepath.Ext(base))
	}
	return sanitizeIdent(base)
}

var identSanitizeRe = regexp.MustCompile(`[^a-z0-9_]`)

// sanitizeIdent turns an arbitrary string into a valid lowercase dataset id.
func sanitizeIdent(s string) string {
	s = identSanitizeRe.ReplaceAllString(strings.ToLower(s), "_")
	if s == "" || s[0] >= '0' && s[0] <= '9' {
		s = "g_" + s
	}
	if len(s) > 63 {
		s = s[:63]
	}
	return s
}

func renderDataset(id string, cols []columnYML, tenantCol, manifestPointer, provenance string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Dataset contract, scaffolded (%s). Review before shipping.\n", provenance)
	fmt.Fprintf(&b, "id: %s\n", id)
	fmt.Fprintf(&b, "description: %s\n", id)
	fmt.Fprintf(&b, "manifest: %s\n", manifestPointer)
	if tenantCol != "" {
		fmt.Fprintf(&b, "tenant_column: %s   # bound from the caller's API key, never a request\n", tenantCol)
	}
	fmt.Fprintln(&b, "schema:")
	for _, c := range cols {
		fmt.Fprintf(&b, "  - { name: %s, type: %s }\n", c.Name, c.Type)
	}
	return b.String()
}
