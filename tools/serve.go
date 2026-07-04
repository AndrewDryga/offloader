package main

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func init() {
	register(command{
		name:    "serve",
		summary: "pull and run the container against a local project or a gs://|s3:// bucket (for POCs)",
		run:     runServe,
	})
}

// runServe boots the published image against a local project so a POC is one command
// instead of a long `docker run`. It validates the config first, so a broken project
// fails here rather than as a container that never becomes ready.
func runServe(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprintln(stderr, "usage: offloader serve [flags] <project-dir | offloader.yml | gs://…/ | s3://…/>")
		fs.PrintDefaults()
	}
	image := fs.String("image", "ghcr.io/andrewdryga/offloader:edge", "container image to run")
	apiPort := fs.Int("api-port", 8088, "host port for the product API (auto-bumped if taken)")
	adminPort := fs.Int("admin-port", 8089, "host port for the admin surface, loopback-bound (auto-bumped if taken)")
	cacheVol := fs.String("cache-volume", "offloader-poc-cache", "Docker volume for the materialization cache")
	noPull := fs.Bool("no-pull", false, "skip `docker pull` and use the local image as-is")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	path := "."
	if fs.NArg() > 0 {
		path = fs.Arg(0)
	}

	// A gs://|s3:// path is served as a remote config (no mount); a local path is mounted.
	var configValue, mountDir, target string
	var extraEnv []string
	if isRemoteConfig(path) {
		configValue, target = path, path
		extraEnv = remoteConfigEnv(path)
		// A remote config can't be checked locally — the container validates it on boot.
	} else {
		projectDir, err := resolveProjectDir(path)
		if err != nil {
			fmt.Fprintf(stderr, "offloader serve: %v\n", err)
			return 1
		}
		// Fail fast on a broken config — don't boot a container that can't serve.
		if problems := validateProject(filepath.Join(projectDir, "offloader.yml")); len(problems) > 0 {
			fmt.Fprintf(stderr,
				"offloader serve: %d config problem(s) — run: offloader validate --config %s\n",
				len(problems), filepath.Join(projectDir, "offloader.yml"))
			return 1
		}
		configValue = "/etc/offloader/offloader.yml"
		mountDir, target = projectDir, projectDir
	}

	if _, err := exec.LookPath("docker"); err != nil {
		fmt.Fprintln(stderr, "offloader serve: docker not found on PATH")
		return 1
	}

	secret, err := randomSecret()
	if err != nil {
		fmt.Fprintf(stderr, "offloader serve: %v\n", err)
		return 1
	}

	if !*noPull {
		fmt.Fprintf(stdout, "offloader serve: pulling %s …\n", *image)
		if code := runDocker(stdout, stderr, "pull", *image); code != 0 {
			fmt.Fprintln(stderr, "offloader serve: docker pull failed")
			return code
		}
	}

	// Pick the first free host ports at/above the requested ones, so serve doesn't die on a
	// collision with whatever local dev already holds 8088/8089 — the printed URL shows what it got.
	apiHost := firstFreePort(*apiPort)
	adminStart := *adminPort
	if adminStart <= apiHost {
		adminStart = apiHost + 1
	}
	adminHost := firstFreePort(adminStart)

	paint := colorizer(stdout)
	fmt.Fprintf(stdout, "%s %s\n", paint(cBold, "offloader serve:"), target)
	fmt.Fprintf(stdout, "  %s  %s   %s\n", paint(cBold+cGreen, "API  "),
		paint(cCyan, fmt.Sprintf("http://localhost:%d", apiHost)), paint(cDim, "← curl your endpoints here"))
	fmt.Fprintf(stdout, "  %s  %s   %s\n", paint(cBold+cYellow, "admin"),
		paint(cCyan, fmt.Sprintf("http://127.0.0.1:%d", adminHost)), paint(cDim, "health/metrics/docs (keep private)"))
	fmt.Fprintf(stdout, "  %s  curl -fsS http://127.0.0.1:%d/ready\n", paint(cDim, "ready"), adminHost)
	fmt.Fprintf(stdout, "  %s  curl -fsS http://127.0.0.1:%d/docs   %s\n",
		paint(cDim, "docs "), adminHost, paint(cDim, "# lists the endpoints you can call"))
	fmt.Fprintf(stdout, "  %s  Ctrl-C\n", paint(cDim, "stop "))
	return runDocker(stdout, stderr,
		dockerRunArgs(*image, configValue, mountDir, apiHost, adminHost, *cacheVol, secret, extraEnv)...)
}

// dockerRunArgs builds the `docker run …` argument list. Pure and unit-tested. `mountDir`
// is empty for a remote (gs://|s3://) config — then OFFLOADER_CONFIG is the URL and nothing is
// mounted; `extraEnv` carries any object-store credentials.
func dockerRunArgs(image, configValue, mountDir string, apiPort, adminPort int, cacheVol, secret string, extraEnv []string) []string {
	args := []string{
		"run", "--rm",
		"-e", "OFFLOADER_CONFIG=" + configValue,
		"-e", "OFFLOADER_SECRET_KEY_BASE=" + secret,
		// Tell the container to LISTEN on the ports we publish (not its 4000/4001 default), so
		// its own startup logs and the URL serve prints agree — otherwise it says "8088" while
		// the container logs "Access at :4000", which sends people curling the wrong port.
		"-e", fmt.Sprintf("OFFLOADER_API_PORT=%d", apiPort),
		"-e", fmt.Sprintf("OFFLOADER_ADMIN_PORT=%d", adminPort),
	}
	for _, e := range extraEnv {
		args = append(args, "-e", e)
	}
	args = append(args,
		"-p", fmt.Sprintf("%d:%d", apiPort, apiPort),
		"-p", fmt.Sprintf("127.0.0.1:%d:%d", adminPort, adminPort),
	)
	if mountDir != "" {
		args = append(args, "-v", mountDir+":/etc/offloader:ro")
	}
	return append(args, "-v", cacheVol+":/var/lib/offloader/cache", image)
}

// ANSI colors for the serve banner. colorizer returns a painter that is a no-op unless stdout is
// a real terminal and NO_COLOR (https://no-color.org) is unset — so color never leaks into a pipe.
const (
	cReset  = "\x1b[0m"
	cBold   = "\x1b[1m"
	cDim    = "\x1b[2m"
	cGreen  = "\x1b[32m"
	cYellow = "\x1b[33m"
	cCyan   = "\x1b[36m"
)

func colorizer(w io.Writer) func(code, s string) string {
	on := colorEnabled(w)
	return func(code, s string) string {
		if !on {
			return s
		}
		return code + s + cReset
	}
}

func colorEnabled(w io.Writer) bool {
	if _, ok := os.LookupEnv("NO_COLOR"); ok {
		return false
	}
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// firstFreePort returns the first port >= start that nothing is already listening on. It probes
// loopback (which also catches 0.0.0.0 binds and avoids a macOS firewall prompt) and only holds
// the port momentarily, so there's a small TOCTOU window before docker binds — fine for a local
// POC. Falls back to start after a bounded scan so docker surfaces the real bind error.
func firstFreePort(start int) int {
	for p := start; p <= 65535 && p < start+64; p++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err != nil {
			continue
		}
		_ = ln.Close()
		return p
	}
	return start
}

// isRemoteConfig reports whether path is an object-store config URL to serve directly
// (OFFLOADER_CONFIG=<url>) rather than a local directory to mount.
func isRemoteConfig(path string) bool {
	return strings.HasPrefix(path, "gs://") || strings.HasPrefix(path, "s3://")
}

// remoteConfigEnv forwards any object-store credentials set in the environment, and defaults a
// gs:// bucket to anonymous (public) access when no GCS auth is configured — so
// `offloader serve gs://<public-bucket>/` just works with nothing else to set.
func remoteConfigEnv(configURL string) []string {
	var env []string
	gcsAuthSet := false
	for _, k := range []string{
		"OFFLOADER_GCS_AUTH", "OFFLOADER_GCS_TOKEN",
		"OFFLOADER_S3_AUTH", "OFFLOADER_S3_TYPE", "OFFLOADER_S3_KEY_ID", "OFFLOADER_S3_SECRET",
		"OFFLOADER_S3_REGION", "OFFLOADER_S3_ENDPOINT", "OFFLOADER_S3_URL_STYLE",
		"OFFLOADER_S3_USE_SSL", "OFFLOADER_S3_SESSION_TOKEN",
	} {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
			if k == "OFFLOADER_GCS_AUTH" {
				gcsAuthSet = true
			}
		}
	}
	if strings.HasPrefix(configURL, "gs://") && !gcsAuthSet {
		env = append(env, "OFFLOADER_GCS_AUTH=none")
	}
	return env
}

// runDocker runs `docker <args>` with the container's output streamed through, returning
// its exit code (so Ctrl-C / a failed image propagates).
func runDocker(stdout, stderr io.Writer, args ...string) int {
	cmd := exec.Command("docker", args...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		return 1
	}
	return 0
}

// resolveProjectDir accepts a project directory or a path to its offloader.yml and returns
// the absolute directory, erroring if there is no offloader.yml to serve.
func resolveProjectDir(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("%s: %w", path, err)
	}
	if !info.IsDir() {
		if filepath.Base(abs) != "offloader.yml" {
			return "", fmt.Errorf("%s is not a directory or an offloader.yml", path)
		}
		abs = filepath.Dir(abs)
	}
	if _, err := os.Stat(filepath.Join(abs, "offloader.yml")); err != nil {
		return "", fmt.Errorf("%s has no offloader.yml", abs)
	}
	return abs, nil
}

// randomSecret returns a fresh OFFLOADER_SECRET_KEY_BASE (equivalent to `openssl rand -base64 48`).
func randomSecret() (string, error) {
	buf := make([]byte, 48)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(buf), nil
}
