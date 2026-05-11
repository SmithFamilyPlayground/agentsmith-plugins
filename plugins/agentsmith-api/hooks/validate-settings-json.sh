#!/usr/bin/env bash
# validate-settings-json.sh — PostToolUse hook. When a *settings*.json
# file is edited, verify it still parses as valid JSON. A broken
# settings.json silently breaks SessionStart on next launch; catching
# it on save is much friendlier than discovering it on relaunch.
#
# This is a syntax check only. Full $schema validation would be nicer
# but adds an external dep (ajv / jsonschema); deferred.

set -euo pipefail

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input")"

case "$file_path" in
  *settings*.json) ;;
  *) exit 0 ;;
esac

if ! jq . "$file_path" >/dev/null 2>&1; then
  printf 'validate-settings-json: %s is not valid JSON.\n' "$file_path" >&2
  jq . "$file_path" 2>&1 >&2 || true
  # PostToolUse can't block, but a non-zero exit is visible.
  exit 1
fi

exit 0
