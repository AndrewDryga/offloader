package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

func init() {
	register(command{
		name:    "manifest",
		summary: "manifest subcommands: `manifest validate <path>`",
		run:     runManifest,
	})
}

func runManifest(args []string, stdout, stderr io.Writer) int {
	if len(args) < 2 || args[0] != "validate" {
		fmt.Fprintln(stderr, "usage: offloader manifest validate <path>")
		return 2
	}
	return report(stdout, stderr, validateManifest(args[1]), "manifest OK")
}

type manifestJSON struct {
	DatasetID           string      `json:"dataset_id"`
	SnapshotID          string      `json:"snapshot_id"`
	CreatedAt           string      `json:"created_at"`
	Watermark           string      `json:"watermark"`
	Schema              []columnYML `json:"schema"`
	Files               []fileJSON  `json:"files"`
	PartitionColumns    *[]string   `json:"partition_columns"`
	SortColumns         *[]string   `json:"sort_columns"`
	RowCount            *int        `json:"row_count"`
	SizeBytes           *int        `json:"size_bytes"`
	Producer            string      `json:"producer"`
	UpstreamRunID       string      `json:"upstream_run_id"`
	SchemaVersion       *int        `json:"schema_version"`
	DataQualityStatus   string      `json:"data_quality_status"`
	CompatibilityPolicy string      `json:"compatibility_policy"`
}

type fileJSON struct {
	Path   string `json:"path"`
	Format string `json:"format"`
}

var snapshotRe = regexp.MustCompile(`^[A-Za-z0-9:_.\-]{1,200}$`)

// validateManifest mirrors the gateway's Offloader.Manifest.load checks: required
// fields, snapshot-id format, ISO timestamps, schema, file existence, and value sets.
func validateManifest(path string) findings {
	var out findings
	rel := filepath.Base(path)

	b, err := os.ReadFile(path)
	if err != nil {
		out.add(rel, "", "missing_file", "cannot read manifest: "+err.Error(), "")
		return out
	}
	var m manifestJSON
	if err := json.Unmarshal(b, &m); err != nil {
		out.add(rel, "", "invalid_json", "invalid JSON: "+err.Error(), "")
		return out
	}

	if !safeIdent(m.DatasetID) {
		out.add(rel, "dataset_id", "unsafe_identifier", fmt.Sprintf("dataset_id %q is missing or not a safe identifier", m.DatasetID), "")
	}
	if !snapshotRe.MatchString(m.SnapshotID) {
		out.add(rel, "snapshot_id", "invalid_snapshot_id", fmt.Sprintf("snapshot_id %q is empty or has invalid characters", m.SnapshotID), "letters, digits, and :_.- only")
	}
	checkTimestamp(rel, "created_at", m.CreatedAt, &out)
	checkTimestamp(rel, "watermark", m.Watermark, &out)
	checkManifestSchema(rel, m.Schema, &out)
	checkColumnRefs(rel, "partition_columns", m.PartitionColumns, m.Schema, &out)
	checkColumnRefs(rel, "sort_columns", m.SortColumns, m.Schema, &out)
	checkFiles(rel, filepath.Dir(path), m.Files, &out)
	requireNonEmpty(rel, "producer", m.Producer, &out)
	requireNonEmpty(rel, "upstream_run_id", m.UpstreamRunID, &out)
	requireField(rel, "row_count", m.RowCount, &out)
	requireField(rel, "size_bytes", m.SizeBytes, &out)
	requireField(rel, "schema_version", m.SchemaVersion, &out)
	oneOf(rel, "data_quality_status", m.DataQualityStatus, []string{"passed", "warning", "failed"}, "invalid_value", &out)
	oneOf(rel, "compatibility_policy", m.CompatibilityPolicy, []string{"additive_only", "exact"}, "invalid_compatibility_policy", &out)
	return out
}

func checkManifestSchema(rel string, schema []columnYML, out *findings) {
	if len(schema) == 0 {
		out.add(rel, "schema", "missing", "schema is required and must be non-empty", "")
		return
	}
	var names []string
	for i, c := range schema {
		p := fmt.Sprintf("schema[%d]", i)
		if !safeColumn(c.Name) {
			out.add(rel, p+".name", "unsafe_identifier", fmt.Sprintf("column name %q is not a safe identifier", c.Name), "")
		}
		if !supportedTypes[c.Type] {
			out.add(rel, p+".type", "unsupported_type", fmt.Sprintf("type %q is not supported", c.Type), "")
		}
		names = append(names, c.Name)
	}
	for _, d := range duplicates(names) {
		out.add(rel, "schema", "duplicate_column", "duplicate column: "+d, "")
	}
}

func checkFiles(rel, dir string, files []fileJSON, out *findings) {
	if len(files) == 0 {
		out.add(rel, "files", "missing", "files is required and must be non-empty", "")
		return
	}
	for i, f := range files {
		p := fmt.Sprintf("files[%d]", i)
		if f.Format != "csv" && f.Format != "parquet" {
			out.add(rel, p+".format", "unsupported_type", fmt.Sprintf("file format %q is not supported", f.Format), "csv or parquet")
		}
		if f.Path == "" {
			out.add(rel, p+".path", "missing", "file path is required", "")
			continue
		}
		// A remote URL (s3://, gs://, https://, …) is trusted; only local files are stat'd.
		if isRemotePath(f.Path) {
			continue
		}
		full := f.Path
		if !filepath.IsAbs(full) {
			full = filepath.Join(dir, f.Path)
		}
		if _, err := os.Stat(full); err != nil {
			out.add(rel, p+".path", "missing_file", fmt.Sprintf("file %q does not exist relative to the manifest", f.Path), "")
		}
	}
}

func checkTimestamp(rel, field, value string, out *findings) {
	// created_at/watermark are required by the gateway, so an absent/empty value is a
	// finding here too — not a silent pass the container then rejects at load.
	if value == "" {
		out.add(rel, field, "missing", "required field "+field+" is missing", "")
		return
	}
	if _, err := time.Parse(time.RFC3339, value); err != nil {
		out.add(rel, field, "invalid_timestamp", fmt.Sprintf("%s %q is not an ISO-8601 timestamp", field, value), "")
	}
}

// partition_columns / sort_columns are required and must reference schema columns — the
// gateway's Manifest.load enforces both; mirror it so this pre-check can't greenlight a
// manifest the container will reject at refresh.
func checkColumnRefs(rel, field string, cols *[]string, schema []columnYML, out *findings) {
	if cols == nil {
		out.add(rel, field, "missing", "required field "+field+" is missing", "")
		return
	}
	names := map[string]bool{}
	for _, c := range schema {
		names[c.Name] = true
	}
	for _, col := range *cols {
		if !names[col] {
			out.add(rel, field, "unknown_column", fmt.Sprintf("%s references %q which is not in the schema", field, col), "")
		}
	}
}

func requireNonEmpty(rel, field, value string, out *findings) {
	if value == "" {
		out.add(rel, field, "missing", field+" is required", "")
	}
}

func requireField[T any](rel, field string, ptr *T, out *findings) {
	if ptr == nil {
		out.add(rel, field, "missing", field+" is required", "")
	}
}

func oneOf(rel, field, value string, allowed []string, code string, out *findings) {
	for _, a := range allowed {
		if value == a {
			return
		}
	}
	out.add(rel, field, code, fmt.Sprintf("%s %q is invalid", field, value), "one of: "+fmt.Sprint(allowed))
}
