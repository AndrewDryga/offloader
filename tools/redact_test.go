package main

import (
	"strings"
	"testing"
)

func TestRedactMasksSecretsButNotSafeHashes(t *testing.T) {
	in := `version: 1
secret_key_base: "abc123SECRETbase"
OFFLOADER_ADMIN_TOKEN=supersecrettoken
password: hunter2
source_uri: s3://AKIAEXAMPLEID:topSecretKey@bucket/prefix
Authorization: Bearer offl_deadbeefcafe
CREATE OR REPLACE SECRET offloader_store (TYPE HTTP, BEARER_TOKEN 'ya29.gcsAccessToken');
hash: "745ce437a64ab1f020c303be50aa3785e742b72e61533d692f7aa024ff16b121"`

	out := redact(in)

	for _, leak := range []string{"abc123SECRETbase", "supersecrettoken", "hunter2", "topSecretKey", "offl_deadbeefcafe", "ya29.gcsAccessToken"} {
		if strings.Contains(out, leak) {
			t.Errorf("redact leaked %q:\n%s", leak, out)
		}
	}
	// a one-way key hash is NOT a secret and must stay (so operators can correlate keys)
	if !strings.Contains(out, "745ce437a64ab1f020c303be50aa3785e742b72e61533d692f7aa024ff16b121") {
		t.Error("redact should not mask a safe sha256 hash")
	}
	if !strings.Contains(out, mask) {
		t.Error("expected REDACTED markers in the output")
	}
}
