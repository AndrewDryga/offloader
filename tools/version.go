package main

import (
	"fmt"
	"io"
)

// version is the build version, overridable at build time:
//
//	go build -ldflags "-X main.version=1.2.3" -o offloader .
var version = "dev"

func init() {
	register(command{
		name:    "version",
		summary: "print the offloader helper version",
		run: func(_ []string, stdout, _ io.Writer) int {
			fmt.Fprintln(stdout, version)
			return 0
		},
	})
}
