#!/usr/bin/env bash
# signal-handler.sh — Stop + UserPromptSubmit hook (toggle-gated).
#
# Phase-2a stub. Spec §L.3.2 describes the full contract:
#   - Drains the per-agent comms buffer.
#   - Handles signal.* inline per §L.6 (pause / resume / wrap_up /
#     halt / terminate, with the §4.1 paused-state precedence matrix).
#   - Re-publishes non-signal events to deferred-events NDJSON.
#
# Phase-2a: the wire-protocol envelopes (§3-§7) aren't on the surface
# yet (the existing agentsmith-comms plugin ships v0.0.1 lifecycle
# nudges; the v1 envelope migration lands when the MCP server lands).
# This stub exists so the hook can be wired into settings.json today
# and become functional on phase-2b without a re-wire.
#
# Toggle: same as routing-loaded-emitter — reads
# agentsmith_api.subagent_memory_lifecycle from .claude/settings.json.
# Default true (sub-agent shape). Parent agents (toggle=false) get
# signal honouring from claude-persistent-memory, not from here.
#
# Exit 0 always — hooks must not block the turn or session.

set -euo pipefail

# Same toggle reader as routing-loaded-emitter.sh — duplicated rather
# than sourced because hooks are independent processes and the
# duplication is small.
toggle_value() {
    local settings_path="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json"
    if [ ! -f "$settings_path" ]; then
        printf 'true\n'; return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        local v
        v="$(jq -r '.agentsmith_api.subagent_memory_lifecycle // "true"' < "$settings_path" 2>/dev/null || true)"
        if [ -z "$v" ] || [ "$v" = "null" ]; then printf 'true\n'; else printf '%s\n' "$v"; fi
        return 0
    fi
    if grep -qE '"subagent_memory_lifecycle"[[:space:]]*:[[:space:]]*false' "$settings_path"; then
        printf 'false\n'
    else
        printf 'true\n'
    fi
}

toggle="$(toggle_value)"
if [ "$toggle" = "false" ]; then
    exit 0
fi

# Phase-2a stub. No-op.
exit 0
