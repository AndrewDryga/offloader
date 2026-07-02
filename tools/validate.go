package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
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

type projectYML struct {
	Version      int    `yaml:"version"`
	DatasetsDir  string `yaml:"datasets_dir"`
	EndpointsDir string `yaml:"endpoints_dir"`
	Keys         string `yaml:"keys"`
	Auth         string `yaml:"auth"`
}

type columnYML struct {
	Name string `yaml:"name"`
	Type string `yaml:"type"`
}

type sourceYML struct {
	Type            string `yaml:"type"`
	Bucket          string `yaml:"bucket"`
	Prefix          string `yaml:"prefix"`
	IntervalSeconds int    `yaml:"interval_seconds"`
}

type datasetYML struct {
	ID           string      `yaml:"id"`
	Manifest     string      `yaml:"manifest"`
	Source       *sourceYML  `yaml:"source"`
	TenantColumn string      `yaml:"tenant_column"`
	Schema       []columnYML `yaml:"schema"`
}

type paramYML struct {
	Name    string            `yaml:"name"`
	Type    string            `yaml:"type"`
	Enum    []string          `yaml:"enum"`
	Aliases map[string]string `yaml:"aliases"`
}

type endpointYML struct {
	Name    string `yaml:"name"`
	Dataset string `yaml:"dataset"`
	Tenant  struct {
		Column string `yaml:"column"`
	} `yaml:"tenant"`
	Params       []paramYML `yaml:"params"`
	Combinations [][]string `yaml:"combinations"`
	Columns      []string   `yaml:"columns"`
}

type keyYML struct {
	ID        string   `yaml:"id"`
	Hash      string   `yaml:"hash"`
	Tenant    string   `yaml:"tenant"`
	Endpoints []string `yaml:"endpoints"`
	Status    string   `yaml:"status"`
}

// validateProject loads and structurally validates a project. It mirrors the gateway's
// key checks (identifiers, references, required fields) as a fast local/CI pre-check;
// the container remains the authority for the full contract.
func validateProject(path string) findings {
	var out findings

	var project projectYML
	if !readYAML(path, "offloader.yml", &project, &out) {
		return out
	}

	dir := filepath.Dir(path)
	datasets := loadDatasets(dir, orDefault(project.DatasetsDir, "datasets"), &out)
	endpoints := loadEndpoints(dir, orDefault(project.EndpointsDir, "endpoints"), datasets, &out)
	if project.Keys != "" {
		loadKeys(filepath.Join(dir, project.Keys), project.Keys, endpointNames(dir, orDefault(project.EndpointsDir, "endpoints")), &out)
	}
	validateAuth(project, endpoints, datasets, &out)
	return out
}

// A dataset's snapshots come from exactly ONE origin: a static manifest path or a
// dynamic source. Mirrors Offloader.Catalog.Dataset snapshot_origin_errors.
func validateSnapshotOrigin(rel string, ds datasetYML, out *findings) {
	switch {
	case ds.Manifest != "" && ds.Source != nil:
		out.add(rel, "source", "conflicting_origin", "manifest and source are mutually exclusive", "keep the static manifest OR the dynamic source, not both")
	case ds.Manifest == "" && ds.Source == nil:
		out.add(rel, "manifest", "missing", "either a manifest path or a source is required", "")
	case ds.Source != nil:
		if ds.Source.Type != "databricks" {
			out.add(rel, "source.type", "invalid_value", fmt.Sprintf("source.type %q is invalid", ds.Source.Type), "one of: databricks")
		}
		if ds.Source.Bucket == "" {
			out.add(rel, "source.bucket", "missing", "source.bucket is required and must be a non-empty string", "")
		}
		if ds.Source.Prefix == "" {
			out.add(rel, "source.prefix", "missing", "source.prefix is required and must be a non-empty string", "")
		}
		if ds.Source.IntervalSeconds < 0 {
			out.add(rel, "source.interval_seconds", "invalid_value", "source.interval_seconds must be a positive integer", "")
		}
	}
}

// auth: required (default) needs a key per request; auth: none serves publicly and is
// only safe when no endpoint is tenant-scoped — mirrors the gateway's cross-check.
func validateAuth(project projectYML, endpoints []endpointYML, datasets map[string]datasetYML, out *findings) {
	switch project.Auth {
	case "", "required", "none":
	default:
		out.add("offloader.yml", "auth", "invalid_value", fmt.Sprintf("auth %q is invalid", project.Auth), "one of: required, none")
		return
	}
	if project.Auth != "none" {
		return
	}
	for _, ep := range endpoints {
		if ds, ok := datasets[ep.Dataset]; ok && ds.TenantColumn != "" {
			out.add("offloader.yml", "auth", "public_tenant_endpoint", fmt.Sprintf("auth: none but endpoint %q is tenant-scoped", ep.Name), "serve non-tenant datasets or set auth: required")
		}
	}
}

func loadDatasets(dir, sub string, out *findings) map[string]datasetYML {
	datasets := map[string]datasetYML{}
	for _, path := range yamlFiles(dir, sub) {
		rel, _ := filepath.Rel(dir, path)
		var ds datasetYML
		if !readYAML(path, rel, &ds, out) {
			continue
		}
		if !safeIdent(ds.ID) {
			out.add(rel, "id", "unsafe_identifier", fmt.Sprintf("dataset id %q is missing or not a safe identifier", ds.ID), "lowercase letters, digits, underscores")
		}
		validateSnapshotOrigin(rel, ds, out)
		schemaNames := datasetSchema(ds, rel, out)
		// tenant_column is optional: absent => a non-tenant (public) dataset.
		if ds.TenantColumn != "" && !schemaNames[ds.TenantColumn] {
			out.add(rel, "tenant_column", "unknown_column", fmt.Sprintf("tenant_column %q is not in the schema", ds.TenantColumn), "")
		}
		if ds.ID != "" {
			datasets[ds.ID] = ds
		}
	}
	return datasets
}

func datasetSchema(ds datasetYML, rel string, out *findings) map[string]bool {
	names := map[string]bool{}
	if len(ds.Schema) == 0 {
		out.add(rel, "schema", "missing", "schema is required and must be a non-empty list", "")
	}
	var all []string
	for i, c := range ds.Schema {
		p := fmt.Sprintf("schema[%d]", i)
		if !safeColumn(c.Name) {
			out.add(rel, p+".name", "unsafe_identifier", fmt.Sprintf("column name %q is missing or not a safe identifier", c.Name), "")
		}
		if !supportedTypes[c.Type] {
			out.add(rel, p+".type", "unsupported_type", fmt.Sprintf("type %q is not supported", c.Type), supportedTypesHint)
		}
		names[c.Name] = true
		all = append(all, c.Name)
	}
	for _, d := range duplicates(all) {
		out.add(rel, "schema", "duplicate_column", "duplicate column: "+d, "")
	}
	return names
}

func loadEndpoints(dir, sub string, datasets map[string]datasetYML, out *findings) []endpointYML {
	var names []string
	var endpoints []endpointYML
	for _, path := range yamlFiles(dir, sub) {
		rel, _ := filepath.Rel(dir, path)
		var ep endpointYML
		if !readYAML(path, rel, &ep, out) {
			continue
		}
		names = append(names, ep.Name)
		endpoints = append(endpoints, ep)
		if !safeIdent(ep.Name) {
			out.add(rel, "name", "unsafe_identifier", fmt.Sprintf("endpoint name %q is missing or not a safe identifier", ep.Name), "")
		}
		ds, ok := datasets[ep.Dataset]
		if !ok {
			out.add(rel, "dataset", "unknown_dataset", fmt.Sprintf("endpoint references unknown dataset %q", ep.Dataset), "")
		} else {
			validateEndpointTenant(rel, ep, ds, out)
		}
		if len(ep.Columns) == 0 {
			out.add(rel, "columns", "missing", "columns allowlist is required and must be non-empty", "")
		}
		declared := map[string]bool{}
		for i, p := range ep.Params {
			if !safeIdent(p.Name) {
				out.add(rel, fmt.Sprintf("params[%d].name", i), "unsafe_identifier", fmt.Sprintf("param name %q is not a safe identifier", p.Name), "")
			}
			declared[p.Name] = true
			validateParamAliases(rel, i, p, out)
		}
		validateCombinations(rel, ep.Combinations, declared, out)
	}
	for _, d := range duplicates(names) {
		out.add(sub, sub, "duplicate_endpoint", "duplicate endpoint name: "+d, "")
	}
	return endpoints
}

// Aliases are a value→value rewrite on string/enum params; for an enum every alias
// target must itself be an allowed enum value. Mirrors Offloader.Catalog.Endpoint.
func validateParamAliases(rel string, i int, p paramYML, out *findings) {
	if len(p.Aliases) == 0 {
		return
	}
	path := fmt.Sprintf("params[%d].aliases", i)
	if p.Type != "string" && p.Type != "enum" {
		out.add(rel, path, "invalid_value", fmt.Sprintf("aliases are not supported on %q params", p.Type), "only string and enum params can declare aliases")
	}
	if p.Type == "enum" {
		allowed := map[string]bool{}
		for _, v := range p.Enum {
			allowed[v] = true
		}
		for k, v := range p.Aliases {
			if !allowed[v] {
				out.add(rel, path, "invalid_value", fmt.Sprintf("alias %q maps to %q which is not an allowed enum value", k, v), "")
			}
		}
	}
}

// Each combination must list declared params, without duplicates. Mirrors
// Offloader.Catalog.Endpoint combinations_errors.
func validateCombinations(rel string, combos [][]string, declared map[string]bool, out *findings) {
	for i, combo := range combos {
		path := fmt.Sprintf("combinations[%d]", i)
		for _, name := range combo {
			if !declared[name] {
				out.add(rel, path, "unknown_param", fmt.Sprintf("combination references param %q which is not declared", name), "")
			}
		}
		for _, d := range duplicates(combo) {
			out.add(rel, path, "duplicate_param", "duplicate name: "+d, "")
		}
	}
}

// A tenant dataset requires the endpoint to bind its column; a non-tenant dataset
// forbids a tenant binding. Mirrors Offloader.Catalog.Endpoint tenant_errors.
func validateEndpointTenant(rel string, ep endpointYML, ds datasetYML, out *findings) {
	switch {
	case ds.TenantColumn != "" && ep.Tenant.Column == "":
		out.add(rel, "tenant", "missing", "tenant binding is required for a tenant dataset", fmt.Sprintf("bind %q, or drop tenant_column from the dataset", ds.TenantColumn))
	case ds.TenantColumn != "" && ep.Tenant.Column != ds.TenantColumn:
		out.add(rel, "tenant.column", "tenant_mismatch", fmt.Sprintf("tenant.column %q must equal the dataset tenant_column %q", ep.Tenant.Column, ds.TenantColumn), "")
	case ds.TenantColumn == "" && ep.Tenant.Column != "":
		out.add(rel, "tenant", "tenant_forbidden", fmt.Sprintf("dataset %q has no tenant_column, so this endpoint cannot bind a tenant", ep.Dataset), "remove the tenant binding, or add tenant_column to the dataset")
	}
}

func loadKeys(path, rel string, knownEndpoints map[string]bool, out *findings) {
	var kf struct {
		Keys []keyYML `yaml:"keys"`
	}
	if !readYAML(path, rel, &kf, out) {
		return
	}
	for i, k := range kf.Keys {
		p := fmt.Sprintf("keys[%d]", i)
		if !safeIdent(k.ID) {
			out.add(rel, p+".id", "unsafe_identifier", fmt.Sprintf("key id %q is not a safe identifier", k.ID), "")
		}
		if !isSHA256Hex(k.Hash) {
			out.add(rel, p+".hash", "invalid_value", "hash must be a 64-char lowercase sha256 hex", "store sha256(token), never the token")
		}
		if k.Tenant == "" {
			out.add(rel, p+".tenant", "missing", "key must be bound to a tenant", "")
		}
		if k.Status != "active" && k.Status != "revoked" {
			out.add(rel, p+".status", "invalid_value", fmt.Sprintf("status %q is invalid", k.Status), "one of: active, revoked")
		}
		for _, e := range k.Endpoints {
			if !knownEndpoints[e] {
				out.add(rel, p+".endpoints", "unknown_endpoint", fmt.Sprintf("key grants unknown endpoint %q", e), "")
			}
		}
	}
}

func endpointNames(dir, sub string) map[string]bool {
	names := map[string]bool{}
	for _, path := range yamlFiles(dir, sub) {
		var ep endpointYML
		if b, err := os.ReadFile(path); err == nil {
			_ = yaml.Unmarshal(b, &ep)
			if ep.Name != "" {
				names[ep.Name] = true
			}
		}
	}
	return names
}

func isSHA256Hex(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func yamlFiles(dir, sub string) []string {
	full := filepath.Join(dir, sub)
	var out []string
	for _, ext := range []string{"*.yml", "*.yaml"} {
		matches, _ := filepath.Glob(filepath.Join(full, ext))
		out = append(out, matches...)
	}
	return out
}

func readYAML(path, rel string, into any, out *findings) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		out.add(rel, "", "missing_file", "cannot read file: "+err.Error(), "")
		return false
	}
	if err := yaml.Unmarshal(b, into); err != nil {
		out.add(rel, "", "yaml_error", "could not parse YAML: "+err.Error(), "")
		return false
	}
	return true
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
