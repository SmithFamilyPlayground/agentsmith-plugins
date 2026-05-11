#!/usr/bin/env bash
# binary-sync-reminder.sh — PostToolUse hook. When any of the three
# environment install paths is edited (Dockerfile for fly, homebox-setup.sh
# for the home box, web-setup.sh for the Claude web sandbox), remind
# the editor to mirror binary-install changes in the others.
#
# Per CLAUDE.md "System dependencies for skills" table, the three
# environments must install the same set of binaries (with documented
# exceptions — e.g. sprite is home-box-only, defuddle skips web). This
# hook is a nudge, not a check — the verify-binary-sync skill is the
# audit.

set -euo pipefail

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
basename="${file_path##*/}"

case "$basename" in
  Dockerfile)         others="bootstrap/homebox-setup.sh, bootstrap/web-setup.sh" ;;
  homebox-setup.sh)   others="Dockerfile, bootstrap/web-setup.sh" ;;
  web-setup.sh)       others="Dockerfile, bootstrap/homebox-setup.sh" ;;
  *)                  exit 0 ;;
esac

cat <<EOF >&2
binary-sync-reminder: you edited ${file_path}.
If this added or removed a binary install step, mirror it in: ${others}
See CLAUDE.md → "System dependencies for skills" for the sync rule
and the table of documented per-environment exceptions.

To audit current state, dispatch the verify-binary-sync skill.
EOF
exit 0
