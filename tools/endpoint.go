package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
)

func init() {
	register(command{
		name:    "endpoint",
		summary: "endpoint subcommands: `endpoint test` (call a local endpoint and verify the response)",
		run:     runEndpoint,
	})
}

func runEndpoint(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 || args[0] != "test" {
		fmt.Fprintln(stderr, "usage: offloader endpoint test --url URL --key KEY --endpoint NAME [--params 'a=1&b=2'] [--expect-status N]")
		return 2
	}
	fs := flag.NewFlagSet("endpoint test", flag.ContinueOnError)
	fs.SetOutput(stderr)
	url := fs.String("url", "http://localhost:4000", "gateway API base URL")
	key := fs.String("key", "", "bearer API key")
	name := fs.String("endpoint", "", "endpoint name")
	params := fs.String("params", "", "query string, e.g. 'from=2026-05-30&to=2026-06-01'")
	expect := fs.Int("expect-status", 200, "expected HTTP status")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if *name == "" {
		fmt.Fprintln(stderr, "endpoint test: --endpoint is required")
		return 2
	}

	target := fmt.Sprintf("%s/v1/endpoints/%s", trimSlash(*url), *name)
	if *params != "" {
		target += "?" + *params
	}

	code, body, err := httpGet(target, *key)
	if err != nil {
		fmt.Fprintln(stderr, "endpoint test: "+err.Error())
		return 1
	}
	if code != *expect {
		fmt.Fprintf(stderr, "endpoint test: got status %d, expected %d\n%s\n", code, *expect, body)
		return 1
	}

	// For a success we also verify the response contract; for an expected error the
	// status match is the whole check.
	if *expect != http.StatusOK {
		fmt.Fprintf(stdout, "endpoint test OK: %s returned %d as expected\n", *name, code)
		return 0
	}

	var resp struct {
		Data []json.RawMessage `json:"data"`
		Meta struct {
			SnapshotID string          `json:"snapshot_id"`
			Freshness  json.RawMessage `json:"freshness"`
		} `json:"meta"`
	}
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		fmt.Fprintln(stderr, "endpoint test: response is not JSON: "+err.Error())
		return 1
	}
	if resp.Meta.SnapshotID == "" {
		fmt.Fprintln(stderr, "endpoint test: response missing meta.snapshot_id")
		return 1
	}
	if len(resp.Meta.Freshness) == 0 {
		fmt.Fprintln(stderr, "endpoint test: response missing meta.freshness")
		return 1
	}

	fmt.Fprintf(stdout, "endpoint test OK: %s -> %d rows, snapshot %s\n", *name, len(resp.Data), resp.Meta.SnapshotID)
	return 0
}

func trimSlash(s string) string {
	for len(s) > 0 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}
