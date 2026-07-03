package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitScaffoldsAValidAuthedProject(t *testing.T) {
	proj := filepath.Join(t.TempDir(), "proj")
	var out bytes.Buffer
	if code := runInit([]string{"--out", proj}, &out, io.Discard); code != 0 {
		t.Fatalf("init exit = %d", code)
	}
	if fs := validateProject(filepath.Join(proj, "offloader.yml")); len(fs) != 0 {
		t.Fatalf("scaffolded project does not validate: %v", fs.codes())
	}
	// A working demo key is minted, and its plaintext token is shown once.
	if !strings.Contains(out.String(), "offl_") {
		t.Error("expected a generated bearer token in the output")
	}
}

func TestInitScaffoldsAValidPublicProject(t *testing.T) {
	proj := filepath.Join(t.TempDir(), "pub")
	if code := runInit([]string{"--out", proj, "--public"}, io.Discard, io.Discard); code != 0 {
		t.Fatalf("init exit = %d", code)
	}
	if fs := validateProject(filepath.Join(proj, "offloader.yml")); len(fs) != 0 {
		t.Fatalf("public scaffold does not validate: %v", fs.codes())
	}
	if _, err := os.Stat(filepath.Join(proj, "keys")); err == nil {
		t.Error("a public project must not scaffold a keys/ dir")
	}
}

func TestInitRefusesToClobberWithoutForce(t *testing.T) {
	proj := filepath.Join(t.TempDir(), "p")
	if code := runInit([]string{"--out", proj}, io.Discard, io.Discard); code != 0 {
		t.Fatal("first init failed")
	}
	if code := runInit([]string{"--out", proj}, io.Discard, io.Discard); code == 0 {
		t.Error("a second init must refuse to clobber without --force")
	}
	if code := runInit([]string{"--out", proj, "--force"}, io.Discard, io.Discard); code != 0 {
		t.Error("--force must allow overwriting")
	}
}
