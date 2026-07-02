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
