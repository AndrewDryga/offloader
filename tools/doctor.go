package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os/exec"
)

func init() {
	register(command{
		name:    "doctor",
		summary: "check toolchain, config, and (optionally) a running gateway",
		run:     runDoctor,
	})
}

func runDoctor(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	fs.SetOutput(stderr)
	config := fs.String("config", "", "validate this project config (optional)")
	url := fs.String("admin-url", "", "ping this gateway admin URL (optional)")
	token := fs.String("admin-token", "", "admin token for the gateway ping")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ok := true
	check := func(label string, pass bool, detail string) {
		mark := "ok  "
		if !pass {
			mark = "FAIL"
			ok = false
		}
		fmt.Fprintf(stdout, "  %s  %-14s %s\n", mark, label, detail)
	}

	for _, t := range []string{"docker", "curl"} {
		_, err := exec.LookPath(t)
		check(t, err == nil, choose(err == nil, "found", "not found (needed to run/verify the container)"))
	}

	if *config != "" {
		problems := validateProject(*config)
		check("config", len(problems) == 0,
			choose(len(problems) == 0, *config+" valid",
				fmt.Sprintf("%d problem(s) — run: offloader validate --config %s", len(problems), *config)))
	}

	if *url != "" {
		code, _, err := httpGet(adminURL(*url, "/ready"), *token)
		up := err == nil && code == http.StatusOK
		check("gateway", up, choose(up, *url+" ready", "not ready (admin /ready did not return 200)"))
	}

	if ok {
		fmt.Fprintln(stdout, "doctor: all good")
		return 0
	}
	fmt.Fprintln(stdout, "doctor: issues found above")
	return 1
}

func choose(cond bool, a, b string) string {
	if cond {
		return a
	}
	return b
}
