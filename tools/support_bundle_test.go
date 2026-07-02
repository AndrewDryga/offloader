package main

import (
	"archive/tar"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readTarGz(t *testing.T, path string) map[string]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	out := map[string]string{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(tr)
		out[hdr.Name] = string(b)
	}
	return out
}

func TestSupportBundleRedactsAndManifests(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "offloader.yml"),
		[]byte("version: 1\nsecret_key_base: \"TOPSECRETVALUE\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "keys"), 0o755); err != nil {
		t.Fatal(err)
	}
	// key hashes are safe; the bundle should keep them (they aren't secrets)
	if err := os.WriteFile(filepath.Join(root, "keys/keys.yml"),
		[]byte("keys:\n  - id: k\n    hash: \"deadbeef\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	out := filepath.Join(root, "bundle.tar.gz")
	arts, err := buildBundle(filepath.Join(root, "offloader.yml"), out, "", "", "2026-07-01")
	if err != nil {
		t.Fatal(err)
	}

	files := readTarGz(t, out)

	if strings.Contains(files["config/offloader.yml"], "TOPSECRETVALUE") {
		t.Errorf("secret leaked into the bundle:\n%s", files["config/offloader.yml"])
	}
	if !strings.Contains(files["config/offloader.yml"], mask) {
		t.Error("expected the secret to be redacted")
	}
	if _, ok := files["manifest.json"]; !ok {
		t.Error("bundle is missing manifest.json")
	}
	if !strings.Contains(files["manifest.json"], "sha256") {
		t.Error("manifest should list artifact checksums")
	}
	// config + keys collected (manifest is added after arts is captured for its body)
	if len(arts) < 2 {
		t.Errorf("expected at least config + keys artifacts, got %d: %+v", len(arts), arts)
	}
}
