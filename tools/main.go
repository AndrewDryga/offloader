// Command offloader is optional helper tooling for the Offloader container:
// config/manifest validation, endpoint smoke tests, diagnostics, and redacted
// support bundles. It is NOT required for a normal deployment — the container runs
// from env vars and mounted config alone. Stdlib only; boring by design.
package main

import "os"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}
