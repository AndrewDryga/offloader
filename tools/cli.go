package main

import (
	"fmt"
	"io"
	"sort"
)

// command is one subcommand of the offloader helper. Later tasks (C02–C04) register
// validate / manifest / endpoint / doctor / support-bundle by calling register.
type command struct {
	name    string
	summary string
	// run executes the command and returns a process exit code. It writes results to
	// stdout and errors to stderr, and must never print secrets by default.
	run func(args []string, stdout, stderr io.Writer) int
}

var commands = map[string]command{}

func register(c command) { commands[c.name] = c }

// run dispatches the first argument to a registered command.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		usage(stdout)
		return 0
	}

	// Accept the conventional flag spellings for version alongside the `version` subcommand,
	// so `offloader --version` (what people actually type) prints the version instead of erroring.
	name := args[0]
	if name == "--version" || name == "-v" {
		name = "version"
	}

	c, ok := commands[name]
	if !ok {
		fmt.Fprintf(stderr, "offloader: unknown command %q\n\n", args[0])
		usage(stderr)
		return 2
	}

	return c.run(args[1:], stdout, stderr)
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "offloader — optional helper tooling for the Offloader container.")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Usage: offloader <command> [args]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Commands:")

	names := make([]string, 0, len(commands))
	for n := range commands {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, n := range names {
		fmt.Fprintf(w, "  %-16s %s\n", n, commands[n].summary)
	}
}
