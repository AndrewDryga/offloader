package main

import "regexp"

// The redactor masks secret-looking content before it is ever written into a support
// bundle. It errs toward over-masking: a support bundle is an operator artifact that
// may be shared, so a false positive (a masked non-secret) is fine; a leaked secret
// is not (docs/security-model.md — "Support bundles are redacted").
var (
	// key: value / key = value where the key names a secret. The alternation must cover the
	// WHOLE key (secret_access_key, private_key, …) — matching only "secret" inside
	// "secret_access_key" leaves the value exposed because [:=] can't follow mid-key.
	secretField = regexp.MustCompile(`(?i)((?:secret_key_base|secret_access_key|access_key_id|access_key|private_key|client_secret|secret|token|password|passwd|api[_-]?key|admin_token)"?\s*[:=]\s*)("?)([^"\r\n]+)("?)`)
	// scheme://user:password@host — mask the password half of credentialed URIs.
	credentialedURI = regexp.MustCompile(`([a-zA-Z][a-zA-Z0-9+.\-]*://[^:/@\s]+:)([^@/\s]+)(@)`)
	// Signed-URL signature/credential query params (GCS/S3): ...&X-Goog-Signature=<hex>...
	signedURLParam = regexp.MustCompile(`(?i)([?&](?:x-goog-signature|x-amz-signature|signature|awsaccesskeyid)=)([^&\s"]+)`)
	// Authorization: Bearer <token>.
	bearer = regexp.MustCompile(`(?i)(bearer\s+)(\S+)`)
	// DuckDB secret DDL: BEARER_TOKEN '<token>' (the gcs_bearer object store).
	bearerDDL = regexp.MustCompile(`(?i)(bearer_token\s+')([^']*)(')`)
)

const mask = "***REDACTED***"

// redact masks secret field values, credentialed-URI passwords, signed-URL signatures, and
// bearer tokens. Best-effort over known secret shapes — not a proof of exhaustive redaction
// (the bundle note says so); review a bundle before sharing it widely.
func redact(text string) string {
	out := secretField.ReplaceAllString(text, `${1}${2}`+mask+`${4}`)
	out = credentialedURI.ReplaceAllString(out, `${1}`+mask+`${3}`)
	out = signedURLParam.ReplaceAllString(out, `${1}`+mask)
	out = bearerDDL.ReplaceAllString(out, `${1}`+mask+`${3}`)
	out = bearer.ReplaceAllString(out, `${1}`+mask)
	return out
}
