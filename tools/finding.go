package main

import (
	"fmt"
	"io"
	"regexp"
	"sort"
)

// finding is a stable config/manifest validation error, matching the gateway's
// Offloader.Catalog.Error shape: which file, the field path inside it, a
// machine-stable code, a human message, and an operator hint. Operators see the same
// error whether they run the container or this helper.
type finding struct {
	File    string
	Path    string
	Code    string
	Message string
	Hint    string
}

func (f finding) String() string {
	s := fmt.Sprintf("%s: %s: %s (%s)", f.File, f.Path, f.Message, f.Code)
	if f.Hint != "" {
		s += " — hint: " + f.Hint
	}
	return s
}

type findings []finding

func (fs *findings) add(file, path, code, msg, hint string) {
	*fs = append(*fs, finding{File: file, Path: path, Code: code, Message: msg, Hint: hint})
}

func (fs findings) codes() []string {
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = f.Code
	}
	return out
}

// report prints findings to stderr (or an OK line to stdout) and returns the exit code.
func report(stdout, stderr io.Writer, fs findings, okMsg string) int {
	if len(fs) == 0 {
		fmt.Fprintln(stdout, okMsg)
		return 0
	}

	sort.Slice(fs, func(i, j int) bool {
		if fs[i].File != fs[j].File {
			return fs[i].File < fs[j].File
		}
		return fs[i].Path < fs[j].Path
	})
	for _, f := range fs {
		fmt.Fprintln(stderr, f)
	}
	fmt.Fprintf(stderr, "\n%d problem(s) found\n", len(fs))
	return 1
}

var identRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,62}$`)

func safeIdent(s string) bool { return identRe.MatchString(s) }

var supportedTypes = map[string]bool{
	"DATE": true, "TIMESTAMP": true, "VARCHAR": true, "INTEGER": true,
	"BIGINT": true, "DOUBLE": true, "BOOLEAN": true,
}

func duplicates(names []string) []string {
	seen := map[string]int{}
	for _, n := range names {
		seen[n]++
	}
	var dups []string
	for n, c := range seen {
		if c > 1 {
			dups = append(dups, n)
		}
	}
	sort.Strings(dups)
	return dups
}
