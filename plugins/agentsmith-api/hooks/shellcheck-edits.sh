#!/usr/bin/env bash
# hooks/shellcheck-edits.sh — PostToolUse hook. Lints .sh/.bash files
# immediately after Edit/Write so issues surface locally instead of
# in the pr-review.yml CI run.
#
# Same flags as .github/workflows/pr-review.yml (-S warning, ignore
# SC1090/SC1091 for sourced-file resolution) so local + CI agree.
#
# Skipped (but never blocking) if shellcheck isn't installed; the
# CI run is the backstop in that case.
#
# Header note: filename starts with "shellcheck" but the comment is
# NOT a directive (parser treats `# shc<word>` at column 1 as a
# directive parse; first line of the comment block must therefore
# avoid that prefix).

set -euo pipefail

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input")"

[[ "$file_path" =~ \.(sh|bash)$ ]] || exit 0

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'shellcheck-edits: shellcheck not installed — skipping lint of %s\n' "$file_path" >&2
  exit 0
fi

# Don't gate on findings — surface them, let the CI run be authoritative.
shellcheck -S warning -e SC1090,SC1091 "$file_path" || true
