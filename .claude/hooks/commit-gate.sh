#!/bin/bash
# Fast commit gate: format staged files, block the commit if they're dirty.
# Reads the tool call on stdin; only acts on git commit. Fails open.
set -f          # the file lists below are word-split on purpose; don't also glob-expand a name
IFS=$'\n'       # …and split only on newlines, so a staged filename with a space stays one path
input=$(cat)
echo "$input" | grep -q '"command"[^}]*git commit' || exit 0
staged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null) || exit 0

# Elixir: block the commit if any staged .ex/.exs file isn't mix-format clean.
ex_files=$(echo "$staged" | grep -E '\.exs?$' || true)
if [ -n "$ex_files" ] && command -v mix >/dev/null 2>&1; then
  # shellcheck disable=SC2086  # intentional: split the file list into separate mix-format args
  if ! mix format --check-formatted $ex_files >/dev/null 2>&1; then
    echo "pre-commit blocked — these need mix format:" >&2; echo "  ${ex_files//$'\n'/$'\n'  }" >&2
    echo "fix: mix format   (skip once: git commit --no-verify)" >&2; exit 2
  fi
fi

exit 0
