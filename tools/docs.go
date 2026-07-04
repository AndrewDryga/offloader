package main

import (
	"flag"
	"fmt"
	"io"
	"os/exec"
	"runtime"
)

func init() {
	register(command{
		name:    "docs",
		summary: "print (or open) the admin-port docs URLs for the product API",
		run:     runDocs,
	})
}

func runDocs(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("docs", flag.ContinueOnError)
	fs.SetOutput(stderr)
	url := fs.String("admin-url", "http://localhost:4001", "server admin base URL")
	open := fs.Bool("open", false, "open the endpoint catalog in a browser")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	base := trimSlash(*url)
	catalog := base + "/docs"
	openapi := base + "/openapi.json"

	fmt.Fprintln(stdout, "Generated product-API docs (served on the admin port):")
	fmt.Fprintf(stdout, "  endpoint catalog: %s\n", catalog)
	fmt.Fprintf(stdout, "  OpenAPI spec:     %s\n", openapi)

	if *open {
		if err := openInBrowser(catalog); err != nil {
			fmt.Fprintln(stderr, "docs: could not open a browser: "+err.Error())
			return 1
		}
	}
	return 0
}

func openInBrowser(url string) error {
	var cmd string
	var args []string
	switch runtime.GOOS {
	case "darwin":
		cmd = "open"
	case "windows":
		cmd, args = "cmd", []string{"/c", "start"}
	default:
		cmd = "xdg-open"
	}
	return exec.Command(cmd, append(args, url)...).Start()
}
