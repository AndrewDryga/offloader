#!/bin/bash
# Fast commit gate: format staged files, block the commit if they're dirty.
# Reads the tool call on stdin; only acts on git commit. Fails open.
set -f          # the file lists below are word-split on purpose; don't also glob-expand a name
IFS=$'\n'       # …and split only on newlines, so a staged filename with a space stays one path
input=$(cat)
echo "$input" | grep -q '"command"[^}]*git commit' || exit 0
staged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null) || exit 0

# Elixir: block the commit if any staged .ex/.exs file isn't mix-format clean.
# The mix project lives in gateway/, so run the formatter there — its .formatter.exs
# teaches the formatter phoenix's paren-free `plug`/`pipe_through`; checking from the
# repo root (no .formatter.exs in scope) false-flags those correctly-formatted lines.
ex_files=$(echo "$staged" | grep -E '^gateway/.*\.exs?$' || true)
if [ -n "$ex_files" ] && [ -d gateway ] && command -v mix >/dev/null 2>&1; then
  rel=$(echo "$ex_files" | sed 's#^gateway/##')      # gateway/lib/x.ex -> lib/x.ex
  # shellcheck disable=SC2086  # intentional: split the file list into separate mix-format args
  if ! (cd gateway && mix format --check-formatted $rel) >/dev/null 2>&1; then
    echo "pre-commit blocked — these need mix format:" >&2; echo "  ${ex_files//$'\n'/$'\n'  }" >&2
    echo "fix: (cd gateway && mix format)" >&2; exit 2
  fi
fi

exit 0
