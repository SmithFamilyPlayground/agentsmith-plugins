#!/usr/bin/env bash
# route-guard.sh — PreToolUse path-routing enforcement.
#
# Wires into Edit | Write | MultiEdit | NotebookEdit | Bash. Reads the
# per-session routes cache (written by routing-loaded-emitter.sh at
# SessionStart) and rejects any write whose target path is outside the
# slug's allowed routes (api spec §L.4).
#
# Failure mode is intentionally fail-closed: missing cache, parse error,
# unknown agent slug all reject the call (exit 2). Defensive hooks
# soft-fail; route-guard does not.
#
# Spec references:
#   - api spec §L.3.1 (always-run regardless of toggle).
#   - api spec §L.4 (full enforcement contract).
#
# Input shape (PreToolUse hook contract):
#   JSON on stdin:
#     {
#       "tool_name": "Edit" | "Write" | "MultiEdit" | "NotebookEdit" | "Bash",
#       "tool_input": {
#         "file_path": "...",      # Edit / Write / NotebookEdit
#         "edits": [{file_path:..., ...}, ...],   # MultiEdit
#         "command": "..."          # Bash
#       }
#     }
#
# Exit codes:
#   0 = allow
#   2 = block (a `reason` line is emitted on stderr)
#
# Phase-2a posture:
#   - The cache may not exist yet (no routing-loaded-emitter run for
#     this session). When that happens we fall back to bundled defaults
#     rather than failing closed for everyone. This is a deliberate
#     phase-2a relaxation; phase-2b's session-start emitter is what
#     promotes route-guard to true fail-closed.
#   - Bash command parsing is best-effort: we look for write-shaped
#     constructs (`>`, `>>`, `tee`, `cp`, `mv`, `mkdir`, `install -m`)
#     and check the referenced paths. Pipelines and command-substitution
#     edge cases (api spec §L.4 fine print) are out-of-scope for the
#     phase-2a hook; the verbatim ex-lifecycle parser lands in phase-2b.

set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
while [ -h "$_SELF" ]; do
    _DIR="$(cd -P "$(dirname "$_SELF")" && pwd)"
    _SELF="$(readlink "$_SELF")"
    [[ "$_SELF" != /* ]] && _SELF="$_DIR/$_SELF"
done
HOOK_DIR="$(cd -P "$(dirname "$_SELF")" && pwd)"
PLUGIN_ROOT="$(cd -P "$HOOK_DIR/.." && pwd)"
LIB_DIR="$PLUGIN_ROOT/lib"

api_die()  { printf 'route-guard: error: %s\n' "$*" >&2; exit 2; }
# api_warn is called indirectly from lib/ids.sh (api_validate_roster_slug
# warns when a sam/amy/ema slug appears — they're spec §8.4 deferreds).
# shellcheck disable=SC2317  # called via lib/ids.sh chain
api_warn() { printf 'route-guard: warn: %s\n' "$*" >&2; }

# shellcheck disable=SC1091
. "$LIB_DIR/ids.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/routes.sh"

# Resolve the agent slug. The harness sets CLAUDE_AGENT_SLUG when
# running as a named agent; fall back to TOD_AGENT_NAME, else 'tod'.
slug="${CLAUDE_AGENT_SLUG:-${TOD_AGENT_NAME:-tod}}"

# Read the hook payload (single JSON object on stdin). Tolerate empty
# stdin (some harnesses fire the hook with no payload during tests).
payload="$(cat - 2>/dev/null || true)"
if [ -z "$payload" ]; then
    exit 0
fi

# Tool name. Pull from payload via a tiny grep — keeps the hook free of
# a jq dependency. The harness emits compact JSON, so a single-line
# extract on the `tool_name` field is robust enough for the
# closed-set of tool names we care about.
tool_name="$(printf '%s' "$payload" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$tool_name" ]; then
    # No tool name — probably not a PreToolUse payload. Allow.
    exit 0
fi

# Pull paths to check based on the tool.
declare -a paths
paths=()
case "$tool_name" in
    Edit|Write|NotebookEdit)
        p="$(printf '%s' "$payload" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        if [ -n "$p" ]; then paths+=("$p"); fi
        ;;
    MultiEdit)
        # Pull every file_path occurrence under tool_input.edits.
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            paths+=("$p")
        done < <(printf '%s' "$payload" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -n 's/"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/p')
        ;;
    Bash)
        cmd="$(printf '%s' "$payload" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        if [ -z "$cmd" ]; then exit 0; fi
        # Best-effort write-target extraction. Look for redirection,
        # `tee`, `cp`, `mv`, `install -m`, `mkdir -p` against absolute
        # paths or vault-rooted paths. Pipelines / command substitution
        # are out of scope per the phase-2a posture above.
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            paths+=("$p")
        done < <(printf '%s' "$cmd" | grep -oE '(>>|>|tee|cp|mv|install -m [0-9]+|mkdir -p) +[^ |;&]+' \
                       | awk '{print $NF}')
        ;;
    *)
        exit 0
        ;;
esac

# No paths to check — allow.
if [ "${#paths[@]}" -eq 0 ]; then
    exit 0
fi

# Resolve vault root for path-relativisation. Paths under VAULT_PATH
# (default ~/.secondbrain) are checked relative to the vault. Paths
# outside the vault are allowed (route-guard scopes to vault writes;
# AgentSmith-repo writes are a separate concern).
VAULT_PATH="${VAULT_PATH:-$HOME/.secondbrain}"
VAULT_PATH="${VAULT_PATH%/}"

for p in "${paths[@]}"; do
    # Strip leading whitespace and quoting.
    p="${p#\"}"
    p="${p%\"}"
    p="${p#\'}"
    p="${p%\'}"

    case "$p" in
        "$VAULT_PATH"|"$VAULT_PATH"/*) ;;
        *)
            # Outside the vault — route-guard isn't responsible for it.
            continue
            ;;
    esac

    rel="${p#"$VAULT_PATH"/}"
    # Empty rel = the vault root itself. Allow for meta-agent only.
    if [ -z "$rel" ]; then
        if [ "$slug" = "agentsmith" ]; then
            continue
        else
            api_die "blocked: $slug attempted to write at vault root ($p)"
        fi
    fi

    if ! api_routes_validate_path "$slug" "$rel" 2>/dev/null; then
        api_die "blocked: $slug not allowed to write '$rel' (per routes table — run 'routes.sh validate $rel --slug $slug' for details)"
    fi
done

exit 0
