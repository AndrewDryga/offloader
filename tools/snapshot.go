package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
)

func init() {
	register(command{
		name:    "snapshot",
		summary: "snapshot subcommands: `snapshot status --admin-url URL --admin-token T`",
		run:     runSnapshot,
	})
}

func runSnapshot(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 || args[0] != "status" {
		fmt.Fprintln(stderr, "usage: offloader snapshot status --admin-url URL --admin-token T")
		return 2
	}
	fs := flag.NewFlagSet("snapshot status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	url := fs.String("admin-url", "", "server admin base URL")
	token := fs.String("admin-token", "", "admin token")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if *url == "" {
		fmt.Fprintln(stderr, "snapshot status: --admin-url is required")
		return 2
	}

	diag, err := fetchDiagnostics(*url, *token)
	if err != nil {
		fmt.Fprintln(stderr, "snapshot status: "+err.Error())
		return 1
	}

	var d struct {
		Datasets []struct {
			Dataset string `json:"dataset"`
			Active  struct {
				SnapshotID string `json:"snapshot_id"`
				Watermark  string `json:"watermark"`
				Age        int    `json:"age_seconds"`
			} `json:"active_snapshot"`
			LastAttempted struct {
				Status string `json:"status"`
			} `json:"last_attempted"`
			RefreshError any `json:"refresh_error"`
			Stale        any `json:"stale"`
		} `json:"datasets"`
	}
	if err := json.Unmarshal([]byte(diag), &d); err != nil {
		fmt.Fprintln(stderr, "snapshot status: could not parse diagnostics: "+err.Error())
		return 1
	}

	for _, ds := range d.Datasets {
		fmt.Fprintf(stdout, "%s: active=%s watermark=%s age=%ds last_attempt=%s stale=%v",
			ds.Dataset, ds.Active.SnapshotID, ds.Active.Watermark, ds.Active.Age, ds.LastAttempted.Status, ds.Stale)
		if ds.RefreshError != nil {
			fmt.Fprintf(stdout, " refresh_error=%v", ds.RefreshError)
		}
		fmt.Fprintln(stdout)
	}
	return 0
}
