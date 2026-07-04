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

// Column names are producer-shaped (camelCase, digit-leading) but still must be
// safe to quote into SQL: letters/digits/underscores only. Mirrors
// Offloader.Catalog.Identifier.valid_column?/1.
var columnRe = regexp.MustCompile(`^[A-Za-z0-9_]{1,63}$`)

func safeColumn(s string) bool { return columnRe.MatchString(s) }

var remotePathRe = regexp.MustCompile(`(?i)^(s3|gs|gcs|az|azure|r2|http|https)://`)

// isRemotePath reports whether a manifest file path is a remote URL DuckDB reads over
// the network (httpfs) rather than a local file to be stat'd.
func isRemotePath(s string) bool { return remotePathRe.MatchString(s) }

var supportedTypes = map[string]bool{
	"DATE": true, "TIMESTAMP": true, "VARCHAR": true, "INTEGER": true,
	"BIGINT": true, "DOUBLE": true, "BOOLEAN": true,
	// JSON is a logical type for a nested (STRUCT/MAP/LIST) column served via to_json.
	"JSON": true,
}

const supportedTypesHint = "one of: DATE TIMESTAMP VARCHAR INTEGER BIGINT DOUBLE BOOLEAN JSON"

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
