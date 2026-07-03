package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func init() {
	register(command{
		name:    "support-bundle",
		summary: "collect a redacted support bundle (config + optional diagnostics) into a tar.gz",
		run:     runSupportBundle,
	})
}

func runSupportBundle(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("support-bundle", flag.ContinueOnError)
	fs.SetOutput(stderr)
	config := fs.String("config", "offloader.yml", "path to the project offloader.yml")
	out := fs.String("out", "offloader-support-bundle.tar.gz", "output tar.gz path")
	url := fs.String("admin-url", "", "admin base URL to include redacted /diagnostics (optional)")
	token := fs.String("admin-token", "", "admin token for /diagnostics")
	at := fs.String("at", "", "timestamp label for the manifest (optional)")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	arts, err := buildBundle(*config, *out, *url, *token, *at)
	if err != nil {
		fmt.Fprintln(stderr, "support-bundle: "+err.Error())
		return 1
	}
	fmt.Fprintf(stdout, "wrote %s (%d artifacts, secrets masked — review before sharing)\n", *out, len(arts))
	for _, a := range arts {
		fmt.Fprintf(stdout, "  %s\n", a.Path)
	}
	return 0
}

type artifact struct {
	Path   string `json:"path"`
	Bytes  int    `json:"bytes"`
	SHA256 string `json:"sha256"`
	Source string `json:"source"`
}

// buildBundle writes a redacted tar.gz and returns the artifact list. Everything
// written is passed through redact() first; nothing raw leaves the machine.
func buildBundle(configPath, outPath, url, token, at string) ([]artifact, error) {
	f, err := os.Create(outPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	var arts []artifact
	add := func(name string, content []byte, source string) error {
		sum := sha256.Sum256(content)
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content))}); err != nil {
			return err
		}
		if _, err := tw.Write(content); err != nil {
			return err
		}
		arts = append(arts, artifact{Path: name, Bytes: len(content), SHA256: hex.EncodeToString(sum[:]), Source: source})
		return nil
	}

	dir := filepath.Dir(configPath)
	walkErr := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		switch filepath.Ext(p) {
		case ".yml", ".yaml", ".json":
			raw, rerr := os.ReadFile(p)
			if rerr != nil {
				return rerr
			}
			rel, _ := filepath.Rel(dir, p)
			return add(filepath.Join("config", rel), []byte(redact(string(raw))), "config (redacted)")
		default:
			return nil
		}
	})
	if walkErr != nil {
		return nil, walkErr
	}

	if url != "" {
		if diag, derr := fetchDiagnostics(url, token); derr == nil {
			_ = add("diagnostics.json", []byte(redact(diag)), "gateway (redacted)")
		}
	}

	manifest, _ := json.MarshalIndent(map[string]any{
		"generated_at": at,
		"note":         "Known secret patterns (secret/token/key fields, credentialed URIs, signed-URL signatures, bearer tokens) are masked. Best-effort, not exhaustive — review before sharing widely.",
		"artifacts":    arts,
	}, "", "  ")
	if err := add("manifest.json", manifest, "tool"); err != nil {
		return nil, err
	}
	return arts, nil
}
