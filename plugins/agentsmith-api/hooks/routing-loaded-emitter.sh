#!/usr/bin/env bash
# routing-loaded-emitter.sh — SessionStart hook (toggle-gated).
#
# When subagent_memory_lifecycle=true, this hook:
#   1. Calls routes.sh get --slug <slug>, which writes the routes
#      snapshot to the per-session cache.
#   2. Phase-2a: stops there. Phase-2b emits a lifecycle.routing_loaded
#      envelope on the comms channel (api spec §L.3.2) and awaits
#      svc's state.ready response.
#
# When subagent_memory_lifecycle=false, the hook no-ops the emission
# (route-guard.sh, an always-run hook, still gets a cache because the
# guard's own bundled-default fallback handles missing-cache).
#
# Toggle resolution: read agentsmith_api.subagent_memory_lifecycle
# from ${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json. Default true.
#
# Exit 0 always — even on failure. SessionStart hooks must not block
# the session.

set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
while [ -h "$_SELF" ]; do
    _DIR="$(cd -P "$(dirname "$_SELF")" && pwd)"
    _SELF="$(readlink "$_SELF")"
    [[ "$_SELF" != /* ]] && _SELF="$_DIR/$_SELF"
done
HOOK_DIR="$(cd -P "$(dirname "$_SELF")" && pwd)"
PLUGIN_ROOT="$(cd -P "$HOOK_DIR/.." && pwd)"
CLI_DIR="$PLUGIN_ROOT/cli"

# Settings-toggle reader. Best-effort grep — `jq` if present, else a
# string-match fallback. Default true.
toggle_value() {
    local settings_path="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json"
    if [ ! -f "$settings_path" ]; then
        printf 'true\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        local v
        v="$(jq -r '.agentsmith_api.subagent_memory_lifecycle // "true"' < "$settings_path" 2>/dev/null || true)"
        if [ -z "$v" ] || [ "$v" = "null" ]; then
            printf 'true\n'
        else
            printf '%s\n' "$v"
        fi
        return 0
    fi
    # Fallback: grep for the literal key. Coarse but safe — if the
    # operator wrote `"subagent_memory_lifecycle": false` we catch it;
    # nested overrides aren't supported in the fallback.
    if grep -qE '"subagent_memory_lifecycle"[[:space:]]*:[[:space:]]*false' "$settings_path"; then
        printf 'false\n'
    else
        printf 'true\n'
    fi
}

slug="${CLAUDE_AGENT_SLUG:-${TOD_AGENT_NAME:-tod}}"
toggle="$(toggle_value)"

if [ "$toggle" = "false" ]; then
    # No-op for parent agents (Tod, meta-agent). claude-persistent-
    # memory owns memory lifecycle when toggle=false; route-guard.sh
    # still loads its own snapshot via the bundled-default fallback.
    exit 0
fi

# Toggle=true: warm the routes cache so route-guard reads cached data
# instead of falling back per-call. Suppress stdout; the hook is
# silent unless it fails.
if [ -x "$CLI_DIR/routes.sh" ]; then
    "$CLI_DIR/routes.sh" get --slug "$slug" >/dev/null 2>&1 || true
fi

# Phase-2b will emit `lifecycle.routing_loaded` on the wire here.

exit 0
