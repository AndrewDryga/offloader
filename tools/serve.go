package main

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

func init() {
	register(command{
		name:    "serve",
		summary: "pull and run the container locally against a config path (for POCs)",
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
		fmt.Fprintln(stderr, "usage: offloader serve [flags] <project-dir | offloader.yml>")
		fs.PrintDefaults()
	}
	image := fs.String("image", "ghcr.io/andrewdryga/offloader:edge", "container image to run")
	apiPort := fs.Int("api-port", 4000, "host port for the product API")
	adminPort := fs.Int("admin-port", 4001, "host port for the admin surface (bound to loopback)")
	cacheVol := fs.String("cache-volume", "offloader-poc-cache", "Docker volume for the materialization cache")
	noPull := fs.Bool("no-pull", false, "skip `docker pull` and use the local image as-is")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	path := "."
	if fs.NArg() > 0 {
		path = fs.Arg(0)
	}
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

	fmt.Fprintf(stdout, "offloader serve: %s → http://localhost:%d  (admin on 127.0.0.1:%d)\n",
		projectDir, *apiPort, *adminPort)
	fmt.Fprintf(stdout, "  ready:  curl -fsS http://127.0.0.1:%d/ready\n  stop:   Ctrl-C\n", *adminPort)
	return runDocker(stdout, stderr, dockerRunArgs(*image, projectDir, *apiPort, *adminPort, *cacheVol, secret)...)
}

// dockerRunArgs builds the `docker run …` argument list. Pure and unit-tested; the mount,
// port publishing, and env must match the documented quickstart run command.
func dockerRunArgs(image, projectDir string, apiPort, adminPort int, cacheVol, secret string) []string {
	return []string{
		"run", "--rm",
		"-e", "OFFLOADER_CONFIG=/etc/offloader/offloader.yml",
		"-e", "OFFLOADER_SECRET_KEY_BASE=" + secret,
		"-p", fmt.Sprintf("%d:4000", apiPort),
		"-p", fmt.Sprintf("127.0.0.1:%d:4001", adminPort),
		"-v", projectDir + ":/etc/offloader:ro",
		"-v", cacheVol + ":/var/lib/offloader/cache",
		image,
	}
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
