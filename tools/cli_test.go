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
