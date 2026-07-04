package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
)

func init() {
	register(command{
		name:    "keys",
		summary: "keys subcommands: `keys create` (mint a token + its config hash)",
		run:     runKeys,
	})
}

// mintToken generates a bearer token and the one-way hash stored in keys.yml. The token
// format (`offl_` + 24 random bytes as hex) and the hash (lowercase-hex SHA-256 of the
// full token) are exactly what the server's Offloader.Auth verifies.
func mintToken() (token, hash string, err error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", "", err
	}
	token = "offl_" + hex.EncodeToString(buf)
	sum := sha256.Sum256([]byte(token))
	return token, hex.EncodeToString(sum[:]), nil
}

func runKeys(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 || args[0] != "create" {
		fmt.Fprintln(stderr, "usage: offloader keys create [--id ID] [--tenant T] [--endpoints a,b]")
		return 2
	}
	fs := flag.NewFlagSet("keys create", flag.ContinueOnError)
	fs.SetOutput(stderr)
	id := fs.String("id", "key1", "key id")
	tenant := fs.String("tenant", "TENANT", "bound tenant")
	endpoints := fs.String("endpoints", "", "comma-separated endpoint allowlist")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}

	token, hash, err := mintToken()
	if err != nil {
		fmt.Fprintln(stderr, "keys create: "+err.Error())
		return 1
	}

	eps := "[]"
	if *endpoints != "" {
		eps = "[" + *endpoints + "]"
	}

	fmt.Fprintf(stdout, "Bearer token (shown ONCE — hand it to the consumer, never store it):\n\n  %s\n\n", token)
	fmt.Fprintln(stdout, "Add this to your keys.yml (only the one-way hash is stored):")
	fmt.Fprintf(stdout, "\n  - id: %s\n    hash: \"%s\"\n    tenant: %s\n    endpoints: %s\n    status: active\n", *id, hash, *tenant, eps)
	return 0
}
