package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateAcceptsExampleProject(t *testing.T) {
	fs := validateProject(filepath.Join(exampleDir, "offloader.yml"))
	if len(fs) != 0 {
		t.Fatalf("valid project had findings: %v", fs)
	}
}

// writeProject creates a temp project from a map of relative path -> contents.
func writeProject(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, body := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return filepath.Join(root, "offloader.yml")
}

const goodDataset = `id: customer_usage
manifest: m.json
tenant_column: tenant_id
schema:
  - { name: tenant_id, type: VARCHAR }
  - { name: account_id, type: VARCHAR }
`

const goodEndpoint = `name: usage_summary
dataset: customer_usage
tenant:
  column: tenant_id
params:
  - { name: from, type: date }
columns: [account_id]
`

func TestValidateRejectsUnknownDataset(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             "name: e\ndataset: nope\ntenant:\n  column: tenant_id\ncolumns: [account_id]\n",
	})
	assertCode(t, validateProject(project), "unknown_dataset")
}

func TestValidateRejectsTenantMismatch(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             "name: e\ndataset: customer_usage\ntenant:\n  column: account_id\ncolumns: [account_id]\n",
	})
	assertCode(t, validateProject(project), "tenant_mismatch")
}

func TestValidateRejectsUnsafeIdentifierAndDupColumn(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml": "version: 1\n",
		"datasets/customer_usage.yml": `id: customer_usage
manifest: m.json
tenant_column: tenant_id
schema:
  - { name: tenant_id, type: VARCHAR }
  - { name: tenant_id, type: VARCHAR }
  - { name: "Bad Name", type: VARCHAR }
`,
		"endpoints/e.yml": goodEndpoint,
	})
	fs := validateProject(project)
	assertCode(t, fs, "duplicate_column")
	assertCode(t, fs, "unsafe_identifier")
}

func TestValidateRejectsKeyWithUnknownEndpoint(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\nkeys: keys/keys.yml\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             goodEndpoint,
		"keys/keys.yml": `keys:
  - id: k1
    hash: "` + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + `"
    tenant: tenant_acme
    endpoints: [does_not_exist]
    status: active
`,
	})
	assertCode(t, validateProject(project), "unknown_endpoint")
}

func TestValidateCommandExitCodes(t *testing.T) {
	ok := run([]string{"validate", "--config", filepath.Join(exampleDir, "offloader.yml")}, discard{}, discard{})
	if ok != 0 {
		t.Fatalf("valid project exit = %d, want 0", ok)
	}
}

func TestValidateAcceptsPublicExampleProject(t *testing.T) {
	fs := validateProject("../examples/public-metrics/offloader.yml")
	if len(fs) != 0 {
		t.Fatalf("public example had findings: %v", fs)
	}
}

const publicDataset = `id: champion_stats
manifest: m.json
schema:
  - { name: champion_id, type: VARCHAR }
  - { name: data, type: JSON }
`

const publicEndpoint = `name: champion
dataset: champion_stats
params:
  - { name: champion_id, type: string }
columns: [champion_id, data]
`

func TestValidateAcceptsNonTenantPublicProject(t *testing.T) {
	// A non-tenant dataset + a JSON column + auth: none + an endpoint with no tenant.
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\nauth: none\n",
		"datasets/champion_stats.yml": publicDataset,
		"endpoints/champion.yml":      publicEndpoint,
	})
	if fs := validateProject(project); len(fs) != 0 {
		t.Fatalf("valid public project had findings: %v", fs)
	}
}

func TestValidateRejectsPublicAuthWithTenantEndpoint(t *testing.T) {
	// auth: none is unsafe when an endpoint is tenant-scoped.
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\nauth: none\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             goodEndpoint,
	})
	assertCode(t, validateProject(project), "public_tenant_endpoint")
}

func TestValidateRejectsTenantBindingOnNonTenantDataset(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\n",
		"datasets/champion_stats.yml": publicDataset,
		"endpoints/e.yml":             "name: e\ndataset: champion_stats\ntenant:\n  column: champion_id\ncolumns: [champion_id]\n",
	})
	assertCode(t, validateProject(project), "tenant_forbidden")
}

func TestValidateRejectsMissingTenantOnTenantDataset(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             "name: e\ndataset: customer_usage\ncolumns: [account_id]\n",
	})
	assertCode(t, validateProject(project), "missing")
}

func TestValidateRejectsInvalidAuthMode(t *testing.T) {
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\nauth: sso\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             goodEndpoint,
	})
	assertCode(t, validateProject(project), "invalid_value")
}

func TestValidateCombinationsAndAliases(t *testing.T) {
	base := `name: e
dataset: customer_usage
tenant:
  column: tenant_id
columns: [account_id]
`
	cases := []struct {
		name, endpoint, wantCode string
	}{
		{
			"combination referencing an undeclared param",
			base + "params:\n  - { name: rank, type: string }\ncombinations: [[rank, nope]]\n",
			"unknown_param",
		},
		{
			"duplicate name inside a combination",
			base + "params:\n  - { name: rank, type: string }\ncombinations: [[rank, rank]]\n",
			"duplicate_param",
		},
		{
			"aliases on an integer param",
			base + "params:\n  - { name: n, type: integer, aliases: { a: b } }\n",
			"invalid_value",
		},
		{
			"enum alias target outside the enum",
			base + "params:\n  - { name: rank, type: enum, enum: [gold], aliases: { G: silver } }\n",
			"invalid_value",
		},
	}

	for _, tc := range cases {
		project := writeProject(t, map[string]string{
			"offloader.yml":               "version: 1\n",
			"datasets/customer_usage.yml": goodDataset,
			"endpoints/e.yml":             tc.endpoint,
		})
		fs := validateProject(project)
		if !slicesContains(fs.codes(), tc.wantCode) {
			t.Errorf("%s: expected %q in findings, got %v", tc.name, tc.wantCode, fs.codes())
		}
	}

	// and a fully valid endpoint with both features passes
	valid := base + `params:
  - { name: rank, type: enum, enum: [gold, silver], aliases: { GOLD: gold } }
  - { name: map_code, type: string }
combinations: [[rank], [rank, map_code]]
`
	project := writeProject(t, map[string]string{
		"offloader.yml":               "version: 1\n",
		"datasets/customer_usage.yml": goodDataset,
		"endpoints/e.yml":             valid,
	})
	if fs := validateProject(project); len(fs) != 0 {
		t.Fatalf("valid combinations/aliases endpoint had findings: %v", fs)
	}
}

func slicesContains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

func TestValidateDatasetSource(t *testing.T) {
	cases := []struct {
		name, dataset, wantCode string
	}{
		{
			"manifest and source together",
			"id: d\nmanifest: m.json\nsource: { type: databricks, bucket: b, prefix: p/ }\nschema:\n  - { name: c, type: VARCHAR }\n",
			"conflicting_origin",
		},
		{
			"neither manifest nor source",
			"id: d\nschema:\n  - { name: c, type: VARCHAR }\n",
			"missing",
		},
		{
			"unknown source type",
			"id: d\nsource: { type: s3_sync, bucket: b, prefix: p/ }\nschema:\n  - { name: c, type: VARCHAR }\n",
			"invalid_value",
		},
		{
			"source without bucket",
			"id: d\nsource: { type: databricks, prefix: p/ }\nschema:\n  - { name: c, type: VARCHAR }\n",
			"missing",
		},
	}

	for _, tc := range cases {
		project := writeProject(t, map[string]string{
			"offloader.yml":   "version: 1\n",
			"datasets/d.yml":  tc.dataset,
			"endpoints/e.yml": "name: e\ndataset: d\ncolumns: [c]\n",
		})
		if fs := validateProject(project); !slicesContains(fs.codes(), tc.wantCode) {
			t.Errorf("%s: expected %q, got %v", tc.name, tc.wantCode, fs.codes())
		}
	}

	// a valid source dataset passes
	project := writeProject(t, map[string]string{
		"offloader.yml": "version: 1\n",
		"datasets/d.yml": `id: d
source:
  type: databricks
  bucket: my-bucket
  prefix: prod/lol/table/
  interval_seconds: 300
schema:
  - { name: c, type: VARCHAR }
`,
		"endpoints/e.yml": "name: e\ndataset: d\ncolumns: [c]\n",
	})
	if fs := validateProject(project); len(fs) != 0 {
		t.Fatalf("valid source dataset had findings: %v", fs)
	}
}
