package main

import (
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"
)

func init() {
	register(command{
		name:    "validate",
		summary: "validate a project config (offloader.yml + datasets/endpoints/keys)",
		run:     runValidate,
	})
}

func runValidate(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("validate", flag.ContinueOnError)
	fs.SetOutput(stderr)
	config := fs.String("config", "offloader.yml", "path to the project offloader.yml")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	return report(stdout, stderr, validateProject(*config), "config OK")
}

// columnYML is one schema column (also read by `manifest validate` and `scaffold-dataset`).
type columnYML struct {
	Name string `yaml:"name"`
	Type string `yaml:"type"`
}

// datasetYML is a dataset that validated: what the endpoint rules check against.
type datasetYML struct {
	ID           string
	TenantColumn string
	Schema       []columnYML
}

// endpointRef is what the project-wide checks need from an endpoint that validated.
type endpointRef struct {
	Name, Dataset string
}

var (
	projectKeys = []string{"version", "datasets_dir", "endpoints_dir", "keys", "object_store_mode", "auth"}
	authModes   = []string{"required", "none"}
	datasetKeys = []string{"id", "description", "manifest", "source", "tenant_column", "schema"}
	sourceKeys  = []string{"type", "bucket", "prefix", "interval_seconds"}
	sourceTypes = []string{"databricks"}
	columnTypes = []string{"DATE", "TIMESTAMP", "VARCHAR", "INTEGER", "BIGINT", "DOUBLE", "BOOLEAN", "JSON"}
	keyFields   = []string{"id", "hash", "tenant", "endpoints", "status"}
	keyStatuses = []string{"active", "revoked"}
	hashRe      = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

// validateProject reports every problem in a project, with the server's rules: a port of
// Offloader.Catalog and its Dataset, Endpoint and Key parsers. dev/validation-cases.yml holds
// both to the same findings. As on the server, only datasets and endpoints that validate count
// for the checks that span files (an endpoint's dataset, a key's endpoints, the auth mode).
func validateProject(path string) findings {
	var out findings
	project, ok := readMapping(path, "offloader.yml", &out)
	if !ok {
		return out
	}
	// Stop at a project-level problem: without valid paths there is nothing to load.
	c := checker{rel: "offloader.yml", out: &out}
	c.unknownKeys(project, projectKeys, "")
	for _, key := range []string{"datasets_dir", "endpoints_dir", "keys"} {
		if v := project[key]; v != nil {
			if s, ok := v.(string); !ok || s == "" {
				c.add(key, "invalid_type", key+" must be a non-empty path", "")
			}
		}
	}
	if len(out) > 0 {
		return out
	}

	dir := filepath.Dir(path)
	datasets := loadDatasets(dir, stringOr(project["datasets_dir"], "datasets"), &out)
	endpoints := loadEndpoints(dir, stringOr(project["endpoints_dir"], "endpoints"), datasets, &out)
	if keys, ok := project["keys"].(string); ok {
		known := map[any]bool{}
		for _, ep := range endpoints {
			known[ep.Name] = true
		}
		loadKeys(filepath.Join(dir, keys), keys, known, &out)
	}
	validateAuth(project["auth"], endpoints, datasets, &out)
	return out
}

// checker files findings for one config file.
type checker struct {
	rel string
	out *findings
}

func (c checker) add(path, code, msg, hint string) { c.out.add(c.rel, path, code, msg, hint) }

func (c checker) unknownKeys(m map[any]any, allowed []string, path string) {
	for k := range m {
		if !isOneOf(k, allowed) {
			c.add(join(path, fmt.Sprint(k)), "unknown_field", fmt.Sprintf("unknown field %q", fmt.Sprint(k)), "allowed: "+strings.Join(allowed, ", "))
		}
	}
}

func (c checker) identifier(v any, path string) {
	switch s := v.(type) {
	case string:
		if !safeIdent(s) {
			c.add(path, "unsafe_identifier", fmt.Sprintf("%s %q is not a safe identifier", path, s), "lowercase letters, digits, underscores")
		}
	default:
		c.add(path, "missing", path+" is required", "")
	}
}

// readMapping reads a config file that must hold a YAML mapping; an empty file is an empty one.
func readMapping(path, rel string, out *findings) (map[any]any, bool) {
	v, ok := readYAMLValue(path, rel, out)
	switch m := v.(type) {
	case nil:
		return map[any]any{}, ok
	case map[any]any:
		return m, true
	}
	if ok {
		out.add(rel, "", "invalid_type", "file must contain a YAML mapping", "")
	}
	return nil, false
}

// auth: required (default) needs a key per request; auth: none serves publicly and is only safe
// when no endpoint is tenant-scoped.
func validateAuth(auth any, endpoints []endpointRef, datasets map[string]datasetYML, out *findings) {
	switch {
	case auth == nil:
	case !isOneOf(auth, authModes):
		out.add("offloader.yml", "auth", "invalid_value", fmt.Sprintf("auth %v is invalid", auth), "one of: "+strings.Join(authModes, ", "))
	case auth == "none":
		for _, ep := range endpoints {
			if datasets[ep.Dataset].TenantColumn != "" {
				out.add("offloader.yml", "auth", "public_tenant_endpoint", fmt.Sprintf("auth: none but endpoint %q is tenant-scoped", ep.Name), "a public API cannot enforce tenancy; serve non-tenant datasets or set auth: required")
			}
		}
	}
}

// ── datasets ─────────────────────────────────────────────────────────────────

func loadDatasets(dir, sub string, out *findings) map[string]datasetYML {
	datasets := map[string]datasetYML{}
	var ids []string
	for _, path := range yamlFiles(dir, sub) {
		rel, _ := filepath.Rel(dir, path)
		raw, ok := readMapping(path, rel, out)
		if !ok {
			continue
		}
		before := len(*out)
		validateDataset(rel, raw, out)
		if len(*out) == before {
			ds := buildDataset(raw)
			ids = append(ids, ds.ID)
			datasets[ds.ID] = ds
		}
	}
	if d := duplicates(ids); len(d) > 0 {
		out.add("datasets", "datasets", "duplicate_dataset", "duplicate name(s): "+strings.Join(d, ", "), "")
	}
	return datasets
}

// validateDataset is a port of Offloader.Catalog.Dataset.parse/2.
func validateDataset(rel string, raw map[any]any, out *findings) {
	c := checker{rel: rel, out: out}
	c.unknownKeys(raw, datasetKeys, "")
	c.identifier(raw["id"], "id")
	c.snapshotOrigin(raw["manifest"], raw["source"])

	// tenant_column is optional (a non-tenant dataset); when set it must name a schema column.
	switch col := raw["tenant_column"].(type) {
	case nil:
	case string:
		switch {
		case !safeColumn(col):
			c.add("tenant_column", "unsafe_identifier", fmt.Sprintf("tenant_column %q is not a safe identifier", col), "")
		case !contains(schemaNames(raw["schema"]), col):
			c.add("tenant_column", "unknown_column", fmt.Sprintf("tenant_column %q is not in the schema", col), "it must name a column declared in schema")
		}
	default:
		c.add("tenant_column", "invalid_type", "tenant_column must be a string", "")
	}

	cols, ok := raw["schema"].([]any)
	if !ok || len(cols) == 0 {
		c.add("schema", "missing", "schema is required and must be a non-empty list", "")
		return
	}
	for i, col := range cols {
		path := fmt.Sprintf("schema[%d]", i)
		m, _ := col.(map[any]any)
		if name, ok := m["name"].(string); !ok || !safeColumn(name) {
			c.add(path+".name", "unsafe_identifier", fmt.Sprintf("column name %v is missing or not a safe identifier", m["name"]), "")
		}
		if !isOneOf(m["type"], columnTypes) {
			c.add(path+".type", "unsupported_type", fmt.Sprintf("type %v is not supported", m["type"]), supportedTypesHint)
		}
	}
	if d := duplicates(schemaNames(cols)); len(d) > 0 {
		c.add("schema", "duplicate_column", "duplicate column(s): "+strings.Join(d, ", "), "")
	}
}

// A dataset's snapshots come from exactly one origin: a static manifest path or a dynamic
// source. The case order mirrors the server's snapshot_origin_errors.
func (c checker) snapshotOrigin(manifest, source any) {
	m, isString := manifest.(string)
	s, isMap := source.(map[any]any)
	switch {
	case isString && m != "" && source == nil:
	case manifest == nil && isMap:
		c.unknownKeys(s, sourceKeys, "source")
		if !isOneOf(s["type"], sourceTypes) {
			c.add("source.type", "invalid_value", fmt.Sprintf("source.type %v is invalid", s["type"]), "one of: "+strings.Join(sourceTypes, ", "))
		}
		for _, key := range []string{"bucket", "prefix"} {
			if v, ok := s[key].(string); !ok || v == "" {
				c.add("source."+key, "missing", "source."+key+" is required and must be a non-empty string", "")
			}
		}
		if v := s["interval_seconds"]; v != nil {
			if n, ok := asInt(v); !ok || n <= 0 {
				c.add("source.interval_seconds", "invalid_value", "source.interval_seconds must be a positive integer", "")
			}
		}
	case isString && isMap:
		c.add("source", "conflicting_origin", "manifest and source are mutually exclusive", "keep the static manifest OR the dynamic source, not both")
	case manifest == nil && source == nil:
		c.add("manifest", "missing", "either a manifest path or a source is required", "")
	default:
		c.add("manifest", "invalid_type", "manifest must be a non-empty string", "")
	}
}

func schemaNames(v any) []string {
	cols, _ := v.([]any)
	var names []string
	for _, col := range cols {
		if m, ok := col.(map[any]any); ok {
			if name, ok := m["name"].(string); ok {
				names = append(names, name)
			}
		}
	}
	return names
}

func buildDataset(raw map[any]any) datasetYML {
	ds := datasetYML{ID: raw["id"].(string)}
	ds.TenantColumn, _ = raw["tenant_column"].(string)
	for _, col := range raw["schema"].([]any) {
		m := col.(map[any]any)
		ds.Schema = append(ds.Schema, columnYML{Name: m["name"].(string), Type: m["type"].(string)})
	}
	return ds
}

// ── endpoints ────────────────────────────────────────────────────────────────

// loadEndpoints validates every endpoint file against its dataset and returns the ones that
// pass. Mirrors Offloader.Catalog load_endpoints: an endpoint whose dataset is missing or
// invalid reports only that, and duplicate names count only endpoints that validated.
func loadEndpoints(dir, sub string, datasets map[string]datasetYML, out *findings) []endpointRef {
	var names []string
	var endpoints []endpointRef
	for _, path := range yamlFiles(dir, sub) {
		rel, _ := filepath.Rel(dir, path)
		raw, ok := readMapping(path, rel, out)
		if !ok {
			continue
		}
		id, ok := raw["dataset"].(string)
		if !ok {
			out.add(rel, "dataset", "missing", "dataset is required", "")
			continue
		}
		ds, ok := datasets[id]
		if !ok {
			out.add(rel, "dataset", "unknown_dataset", fmt.Sprintf("endpoint references unknown dataset %q", id), "")
			continue
		}
		before := len(*out)
		validateEndpoint(rel, raw, ds, out)
		if len(*out) == before {
			name := raw["name"].(string)
			names = append(names, name)
			endpoints = append(endpoints, endpointRef{Name: name, Dataset: id})
		}
	}
	if d := duplicates(names); len(d) > 0 {
		out.add("endpoints", "endpoints", "duplicate_endpoint", "duplicate name(s): "+strings.Join(d, ", "), "")
	}
	return endpoints
}

// ── keys ─────────────────────────────────────────────────────────────────────

// loadKeys is a port of Offloader.Catalog load_keys and Offloader.Catalog.Key.parse/4.
func loadKeys(path, rel string, known map[any]bool, out *findings) {
	raw, ok := readMapping(path, rel, out)
	if !ok {
		return
	}
	list, ok := raw["keys"].([]any)
	if !ok {
		out.add(rel, "keys", "missing", "keys file must contain a top-level `keys:` list", "")
		return
	}
	c := checker{rel: rel, out: out}
	var ids []string
	for i, k := range list {
		path := fmt.Sprintf("keys[%d]", i)
		m, ok := k.(map[any]any)
		if !ok {
			c.add(path, "invalid_type", "key must be a mapping", "")
			continue
		}
		before := len(*out)
		c.unknownKeys(m, keyFields, path)
		if id, ok := m["id"].(string); !ok || !safeIdent(id) {
			c.add(path+".id", "unsafe_identifier", fmt.Sprintf("key id %v is missing or not a safe identifier", m["id"]), "")
		}
		if hash, ok := m["hash"].(string); !ok || !hashRe.MatchString(hash) {
			c.add(path+".hash", "invalid_value", "hash must be a 64-char lowercase SHA-256 hex string", "store sha256(token), never the token")
		}
		if tenant, ok := m["tenant"].(string); !ok || tenant == "" {
			c.add(path+".tenant", "missing", "key must be bound to a tenant", "")
		}
		if !isOneOf(m["status"], keyStatuses) {
			c.add(path+".status", "invalid_value", fmt.Sprintf("status %v is invalid", m["status"]), "one of: "+strings.Join(keyStatuses, ", "))
		}
		if eps, ok := m["endpoints"].([]any); !ok || len(eps) == 0 {
			c.add(path+".endpoints", "missing", "key must grant at least one endpoint", "")
		} else {
			for _, ep := range eps {
				if _, isName := ep.(string); !isName || !known[ep] {
					c.add(path+".endpoints", "unknown_endpoint", fmt.Sprintf("key grants unknown endpoint %v", ep), "")
				}
			}
		}
		if len(*out) == before {
			ids = append(ids, m["id"].(string))
		}
	}
	if d := duplicates(ids); len(d) > 0 {
		out.add("keys", "keys", "duplicate_key", "duplicate name(s): "+strings.Join(d, ", "), "")
	}
}

// ── files ────────────────────────────────────────────────────────────────────

func yamlFiles(dir, sub string) []string {
	full := filepath.Join(dir, sub)
	var out []string
	for _, ext := range []string{"*.yml", "*.yaml"} {
		matches, _ := filepath.Glob(filepath.Join(full, ext))
		out = append(out, matches...)
	}
	return out
}

func stringOr(v any, def string) string {
	if s, ok := v.(string); ok && s != "" {
		return s
	}
	return def
}
