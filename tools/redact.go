package main

import "regexp"

// The redactor masks secret-looking content before it is ever written into a support
// bundle. It errs toward over-masking: a support bundle is an operator artifact that
// may be shared, so a false positive (a masked non-secret) is fine; a leaked secret
// is not (docs/security-model.md — "Support bundles are redacted").
var (
	// key: value / key = value where the key names a secret.
	secretField = regexp.MustCompile(`(?i)((?:secret_key_base|secret|token|password|passwd|api[_-]?key|admin_token)\s*[:=]\s*)("?)([^"\r\n]+)("?)`)
	// scheme://user:password@host — mask the password half of credentialed URIs.
	credentialedURI = regexp.MustCompile(`([a-zA-Z][a-zA-Z0-9+.\-]*://[^:/@\s]+:)([^@/\s]+)(@)`)
	// Authorization: Bearer <token>.
	bearer = regexp.MustCompile(`(?i)(bearer\s+)(\S+)`)
	// DuckDB secret DDL: BEARER_TOKEN '<token>' (the gcs_bearer object store).
	bearerDDL = regexp.MustCompile(`(?i)(bearer_token\s+')([^']*)(')`)
)

const mask = "***REDACTED***"

// redact masks secret field values, credentialed-URI passwords, and bearer tokens.
func redact(text string) string {
	out := secretField.ReplaceAllString(text, `${1}${2}`+mask+`${4}`)
	out = credentialedURI.ReplaceAllString(out, `${1}`+mask+`${3}`)
	out = bearerDDL.ReplaceAllString(out, `${1}`+mask+`${3}`)
	out = bearer.ReplaceAllString(out, `${1}`+mask)
	return out
}
