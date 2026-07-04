package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDockerRunArgs(t *testing.T) {
	args := dockerRunArgs("ghcr.io/x/offloader:edge", "/abs/proj", 8080, 9090, "poc-cache", "s3cr3t")
	joined := strings.Join(args, " ")

	if args[0] != "run" || args[len(args)-1] != "ghcr.io/x/offloader:edge" {
		t.Fatalf("expected run … <image> last; got %v", args)
	}
	for _, want := range []string{
		"OFFLOADER_CONFIG=/etc/offloader/offloader.yml",
		"OFFLOADER_SECRET_KEY_BASE=s3cr3t",
		"8080:4000",
		"127.0.0.1:9090:4001",
		"/abs/proj:/etc/offloader:ro",
		"poc-cache:/var/lib/offloader/cache",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("docker run args missing %q\n  got: %s", want, joined)
		}
	}
}

func TestResolveProjectDir(t *testing.T) {
	dir := t.TempDir()
	yml := filepath.Join(dir, "offloader.yml")
	if err := os.WriteFile(yml, []byte("version: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// A directory containing offloader.yml resolves to that directory.
	got, err := resolveProjectDir(dir)
	if err != nil || got != dir {
		t.Errorf("dir: got (%q, %v), want (%q, nil)", got, err, dir)
	}

	// A path to the offloader.yml itself resolves to its parent directory.
	got, err = resolveProjectDir(yml)
	if err != nil || got != dir {
		t.Errorf("file: got (%q, %v), want (%q, nil)", got, err, dir)
	}

	// A directory without an offloader.yml is an error.
	if _, err := resolveProjectDir(t.TempDir()); err == nil {
		t.Error("empty dir: expected an error, got nil")
	}

	// A non-existent path is an error.
	if _, err := resolveProjectDir(filepath.Join(dir, "nope")); err == nil {
		t.Error("missing path: expected an error, got nil")
	}
}

func TestRandomSecretIsFreshAndLong(t *testing.T) {
	a, err := randomSecret()
	if err != nil {
		t.Fatal(err)
	}
	b, err := randomSecret()
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Error("two secrets were identical")
	}
	if len(a) < 60 { // 48 random bytes → 64 base64 chars
		t.Errorf("secret too short: %d chars", len(a))
	}
}
