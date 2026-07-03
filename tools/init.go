package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

func init() {
	register(command{
		name:    "init",
		summary: "scaffold a new, valid project (offloader.yml + a dataset, endpoint, and key)",
		run:     runInit,
	})
}

func runInit(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(stderr)
	out := fs.String("out", "offloader-project", "directory to create the project in")
	public := fs.Bool("public", false, "scaffold a PUBLIC project (auth: none — no keys, no tenant)")
	force := fs.Bool("force", false, "overwrite existing files")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	files, token, err := scaffoldProject(*public)
	if err != nil {
		fmt.Fprintln(stderr, "init: "+err.Error())
		return 1
	}

	// Refuse to clobber unless --force — a scaffolder must never eat someone's work.
	if !*force {
		for rel := range files {
			if _, err := os.Stat(filepath.Join(*out, rel)); err == nil {
				fmt.Fprintf(stderr, "init: %s already exists (use --force to overwrite)\n", filepath.Join(*out, rel))
				return 1
			}
		}
	}

	for _, rel := range sortedKeys(files) {
		p := filepath.Join(*out, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			fmt.Fprintln(stderr, "init: "+err.Error())
			return 1
		}
		if err := os.WriteFile(p, []byte(files[rel]), 0o644); err != nil {
			fmt.Fprintln(stderr, "init: "+err.Error())
			return 1
		}
	}

	fmt.Fprintf(stdout, "Scaffolded a %s project in %s/:\n\n", modeLabel(*public), *out)
	for _, rel := range sortedKeys(files) {
		fmt.Fprintf(stdout, "  %s\n", filepath.Join(*out, rel))
	}
	fmt.Fprintln(stdout, "\nNext:")
	fmt.Fprintf(stdout, "  1. Edit the dataset schema + endpoint to match your data (every field is commented).\n")
	fmt.Fprintf(stdout, "     Have a snapshot manifest or a CSV already? `offloader scaffold-dataset --from <file>`.\n")
	fmt.Fprintf(stdout, "  2. Point the dataset's `manifest:` at your snapshot (see docs/config-reference.md).\n")
	fmt.Fprintf(stdout, "  3. Check it: `offloader validate --config %s/offloader.yml`.\n", *out)
	if token != "" {
		fmt.Fprintf(stdout, "\nA demo API key was generated. Its bearer token (shown ONCE):\n\n  %s\n\n", token)
		fmt.Fprintln(stdout, "  curl -H \"Authorization: Bearer <token>\" \"localhost:4000/v1/endpoints/events_by_day?from=2026-01-01&to=2026-12-31\"")
	} else {
		fmt.Fprintln(stdout, "\nPublic API — no token needed:")
		fmt.Fprintln(stdout, "  curl \"localhost:4000/v1/endpoints/events_by_day?from=2026-01-01&to=2026-12-31\"")
	}
	return 0
}

func modeLabel(public bool) string {
	if public {
		return "public (auth: none)"
	}
	return "multi-tenant (auth: required)"
}

// scaffoldProject returns the files for a starter project and, for an authed project, a
// freshly minted bearer token to hand the caller. The output is guaranteed to pass
// `offloader validate`.
func scaffoldProject(public bool) (map[string]string, string, error) {
	files := map[string]string{
		"datasets/events.yml":         datasetTemplate(public),
		"endpoints/events_by_day.yml": endpointTemplate(public),
	}

	if public {
		files["offloader.yml"] = publicProjectTemplate
		return files, "", nil
	}

	token, hash, err := mintToken()
	if err != nil {
		return nil, "", err
	}
	files["offloader.yml"] = authedProjectTemplate
	files["keys/keys.yml"] = keysTemplate(hash)
	return files, token, nil
}

func sortedKeys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

const authedProjectTemplate = `# Offloader project — the file OFFLOADER_CONFIG points at.
# It wires together the dataset contracts, endpoint contracts, and API keys of one
# deployment. Paths are relative to this file. Full reference: docs/config-reference.md.
version: 1

datasets_dir: datasets   # one *.yml per dataset (the table contract)
endpoints_dir: endpoints # one *.yml per endpoint (the REST contract)
keys: keys/keys.yml      # API keys, stored as hashes (omit for a public API)

# auth defaults to "required": every request needs a Bearer key. Set "none" for a fully
# public API (accepted only when NO endpoint is tenant-scoped).
auth: required
`

const publicProjectTemplate = `# Offloader project — the file OFFLOADER_CONFIG points at.
# A PUBLIC deployment: no API keys, no tenancy. Paths are relative to this file.
# Full reference: docs/config-reference.md.
version: 1

datasets_dir: datasets
endpoints_dir: endpoints

# Public API: no bearer token required. Accepted only when NO endpoint is tenant-scoped
# (enforced at load), so a public API can never leak per-tenant data.
auth: none
`

func datasetTemplate(public bool) string {
	tenant := ""
	if !public {
		tenant = `
# The column that identifies a tenant. When set, EVERY endpoint on this dataset is
# tenant-scoped: the value is bound from the caller's API key, never a request param.
tenant_column: tenant_id
`
	}
	tenantCol := ""
	if !public {
		tenantCol = "  - { name: tenant_id, type: VARCHAR }\n"
	}
	return `# Dataset contract: the table + the columns Offloader EXPECTS. A snapshot manifest
# declares what actually shipped; a producer change that breaks this contract is
# rejected before it serves. Full reference: docs/config-reference.md#datasetsyml.
id: events
description: One row per (event_date, account_id, event_type).

# Where this dataset's current snapshot manifest lives. Point it at your snapshot
# (Parquet/CSV + a manifest.json). Generate the schema below from an existing manifest
# or a CSV with:  offloader scaffold-dataset --from <file>
manifest: data/events/manifest.json
` + tenant + `
# The columns and their DuckDB types. Supported: DATE TIMESTAMP VARCHAR INTEGER BIGINT
# DOUBLE BOOLEAN JSON (JSON serves a nested STRUCT/MAP/LIST column as a nested object).
schema:
  - { name: event_date, type: DATE }
` + tenantCol + `  - { name: account_id, type: VARCHAR }
  - { name: event_type, type: VARCHAR }
  - { name: event_count, type: BIGINT }
`
}

func endpointTemplate(public bool) string {
	tenant := ""
	if !public {
		tenant = `
# Tenant isolation: the compiler inserts ` + "`tenant_id = <the key's tenant>`" + ` after
# auth. It cannot be supplied or overridden by a request.
tenant:
  column: tenant_id
`
	}
	return `# Endpoint contract: the public REST surface. The compiler turns it into a safe,
# parameterized DuckDB query — consumers never send SQL. Reference:
# docs/config-reference.md#endpointsyml.
name: events_by_day
version: 1
owner: you@example.com
description: Event totals per account over a date range.
dataset: events
serving_mode: local_table
` + tenant + `
freshness:
  max_staleness_minutes: 120   # drives the response's Cache-Control max-age

# The request params. Types: string integer date enum. ` + "`required: false`" + ` params are optional.
params:
  - { name: account_id, type: string, required: false }
  - { name: from, type: date, required: true }
  - { name: to, type: date, required: true }

query:
  group_by: [account_id]
  select:
    - { as: account_id, column: account_id }
    - { as: event_count_total, column: event_count, agg: sum }   # aggs: sum avg min max count
  filters:
    - { column: account_id, op: eq, param: account_id }          # ops: eq gte lte
    - { column: event_date, op: gte, param: from }
    - { column: event_date, op: lte, param: to }
  order_by:
    - { column: event_count_total, dir: desc }

# The ONLY columns a response may contain (an allowlist of the select ` + "`as`" + ` names).
columns: [account_id, event_count_total]

pagination:
  default_limit: 50
  max_limit: 100

cache:
  policy: snapshot   # cache a response until its snapshot changes (or "none")
`
}

func keysTemplate(hash string) string {
	return `# API keys. A key is matched by the SHA-256 hash of its bearer token; the plaintext
# token is NEVER stored. Mint more with: offloader keys create.
#
# A key is scoped to an endpoint allowlist and bound to exactly one tenant; the gateway
# inserts that tenant into every query.
keys:
  - id: demo
    hash: "` + hash + `"
    tenant: tenant_demo
    endpoints: [events_by_day]
    status: active   # or "revoked" to deny it
`
}
