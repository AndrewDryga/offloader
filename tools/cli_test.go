package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestVersionPrintsSomething(t *testing.T) {
	var out bytes.Buffer
	if code := run([]string{"version"}, &out, &out); code != 0 {
		t.Fatalf("version exit = %d, want 0", code)
	}
	if strings.TrimSpace(out.String()) == "" {
		t.Fatal("version printed nothing")
	}
}

func TestVersionFlagAliases(t *testing.T) {
	// `version` also works spelled as a flag — the form people reach for first.
	var ref bytes.Buffer
	run([]string{"version"}, &ref, &ref)
	want := strings.TrimSpace(ref.String())

	for _, flag := range []string{"--version", "-v"} {
		var out, errb bytes.Buffer
		if code := run([]string{flag}, &out, &errb); code != 0 {
			t.Fatalf("%s exit = %d, want 0 (stderr: %q)", flag, code, errb.String())
		}
		if got := strings.TrimSpace(out.String()); got != want {
			t.Fatalf("%s printed %q, want %q", flag, got, want)
		}
	}
}

func TestHelpListsCommands(t *testing.T) {
	var out bytes.Buffer
	if code := run([]string{"help"}, &out, &out); code != 0 {
		t.Fatalf("help exit = %d, want 0", code)
	}
	if !strings.Contains(out.String(), "Usage") {
		t.Fatal("help missing Usage")
	}
	if !strings.Contains(out.String(), "version") {
		t.Fatal("help should list the version command")
	}
}

func TestNoArgsPrintsUsage(t *testing.T) {
	var out bytes.Buffer
	if code := run(nil, &out, &out); code != 0 {
		t.Fatalf("no-args exit = %d, want 0", code)
	}
	if !strings.Contains(out.String(), "Usage") {
		t.Fatal("no-args should print usage")
	}
}

func TestUnknownCommandIsExit2(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"nope"}, &out, &errb); code != 2 {
		t.Fatalf("unknown exit = %d, want 2", code)
	}
	if !strings.Contains(errb.String(), "unknown command") {
		t.Fatalf("expected unknown-command error, got %q", errb.String())
	}
}
