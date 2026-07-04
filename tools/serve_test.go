package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDockerRunArgs(t *testing.T) {
	// Local project: mounted, OFFLOADER_CONFIG points at the mounted file.
	local := dockerRunArgs("ghcr.io/x/offloader:edge", "/etc/offloader/offloader.yml", "/abs/proj", 8080, 9090, "poc-cache", "s3cr3t", nil)
	joined := strings.Join(local, " ")
	if local[0] != "run" || local[len(local)-1] != "ghcr.io/x/offloader:edge" {
		t.Fatalf("expected run … <image> last; got %v", local)
	}
	for _, want := range []string{
		"OFFLOADER_CONFIG=/etc/offloader/offloader.yml",
		"OFFLOADER_SECRET_KEY_BASE=s3cr3t",
		// container listens on the published ports, so its logs match the URL serve prints
		"OFFLOADER_API_PORT=8080",
		"OFFLOADER_ADMIN_PORT=9090",
		"8080:8080",
		"127.0.0.1:9090:9090",
		"/abs/proj:/etc/offloader:ro",
		"poc-cache:/var/lib/offloader/cache",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("local run args missing %q\n  got: %s", want, joined)
		}
	}

	// Remote bucket: no mount, OFFLOADER_CONFIG is the URL, creds carried in extraEnv.
	remote := dockerRunArgs("img", "gs://b/p/", "", 4000, 4001, "cache", "sec", []string{"OFFLOADER_GCS_AUTH=none"})
	rjoined := strings.Join(remote, " ")
	if !strings.Contains(rjoined, "OFFLOADER_CONFIG=gs://b/p/") || !strings.Contains(rjoined, "OFFLOADER_GCS_AUTH=none") {
		t.Errorf("remote run args missing config URL or auth: %s", rjoined)
	}
	if strings.Contains(rjoined, "/etc/offloader:ro") {
		t.Errorf("remote run must NOT mount a config dir: %s", rjoined)
	}
}

func TestFirstFreePortSkipsBusyPort(t *testing.T) {
	// Hold a loopback port, then confirm firstFreePort probes past it rather than returning it —
	// this is what keeps `serve` from dying when its default port is already taken.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	busy := ln.Addr().(*net.TCPAddr).Port

	if got := firstFreePort(busy); got <= busy {
		t.Fatalf("firstFreePort(%d) = %d, want a higher free port (the busy one must be skipped)", busy, got)
	}
}

func TestIsRemoteConfig(t *testing.T) {
	for _, p := range []string{"gs://b/p/", "s3://b/p/"} {
		if !isRemoteConfig(p) {
			t.Errorf("%q should be a remote config", p)
		}
	}
	for _, p := range []string{".", "/abs/proj", "offloader.yml", "https://x/y"} {
		if isRemoteConfig(p) {
			t.Errorf("%q should NOT be a remote config", p)
		}
	}
}

func TestRemoteConfigEnvDefaultsGcsAnonymous(t *testing.T) {
	// With no OFFLOADER_GCS_AUTH set, a gs:// bucket defaults to anonymous/public.
	os.Unsetenv("OFFLOADER_GCS_AUTH")
	env := remoteConfigEnv("gs://offloader-public-samples/offloader/")
	if !containsStr(env, "OFFLOADER_GCS_AUTH=none") {
		t.Errorf("gs:// with no auth should default to OFFLOADER_GCS_AUTH=none; got %v", env)
	}
	// An explicit auth is forwarded, not overridden.
	t.Setenv("OFFLOADER_GCS_AUTH", "bearer")
	env = remoteConfigEnv("gs://private/proj/")
	if !containsStr(env, "OFFLOADER_GCS_AUTH=bearer") || containsStr(env, "OFFLOADER_GCS_AUTH=none") {
		t.Errorf("explicit OFFLOADER_GCS_AUTH must be forwarded verbatim; got %v", env)
	}
}

func containsStr(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
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
