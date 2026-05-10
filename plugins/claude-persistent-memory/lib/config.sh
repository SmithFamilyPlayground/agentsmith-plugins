# shellcheck shell=bash
# lib/config.sh — Memory.Config implementation for local-vault.
#
# Emits a JSON payload matching the api spec §M.4 shape so the same
# consumer code works against either backend. v1 fields:
#
#   thresholds.active_context_pct
#   thresholds.idle_auto_minutes
#   thresholds.idle_auto_context_pct
#   intervals.plan_usage_refresh_minutes
#   intervals.state_md_freshness_warning_hours
#   triggers.consolidate_on_session_end
#   triggers.consolidate_on_topic_boundary
#   triggers.auto_restart_in_flight_subagents_blocked
#   model_overrides       — empty object in phase-1a
#
# Values come from <vault>/config.toml when available; otherwise the
# built-in defaults (mirrored from api spec §M.4).

cpm_config() {
    local vault="${1:-}"
    local cfg=""
    if [ -n "$vault" ] && [ -f "$vault/config.toml" ]; then
        cfg="$vault/config.toml"
    fi

    local active_pct idle_min idle_pct plan_refresh fresh_warn
    local end_trigger topic_trigger restart_block
    active_pct="$(cpm_config_get "$cfg" thresholds active_context_pct 0.30)"
    idle_min="$(cpm_config_get "$cfg" thresholds idle_auto_minutes 90)"
    idle_pct="$(cpm_config_get "$cfg" thresholds idle_auto_context_pct 0.40)"
    plan_refresh="$(cpm_config_get "$cfg" intervals plan_usage_refresh_minutes 5)"
    fresh_warn="$(cpm_config_get "$cfg" intervals state_md_freshness_warning_hours 24)"
    end_trigger="$(cpm_config_get "$cfg" triggers consolidate_on_session_end true)"
    topic_trigger="$(cpm_config_get "$cfg" triggers consolidate_on_topic_boundary true)"
    restart_block="$(cpm_config_get "$cfg" triggers auto_restart_in_flight_subagents_blocked true)"

    # Emit JSON without depending on jq. Values are numeric/boolean
    # by construction; cpm_config_get returns the defaults if absent.
    # `contract_version` matches the api spec §M.4 payload shape so
    # consumer code can gate on contract semantics independent of which
    # backend it's talking to. `backend_version` carries this CLI's own
    # build identifier for diagnostics only.
    cat <<EOF
{
  "contract_version": "agentsmith-api/1.0",
  "backend": "local-vault",
  "backend_version": "claude-persistent-memory/local-vault/0.1.0-phase1a",
  "thresholds": {
    "active_context_pct": $active_pct,
    "idle_auto_minutes": $idle_min,
    "idle_auto_context_pct": $idle_pct
  },
  "intervals": {
    "plan_usage_refresh_minutes": $plan_refresh,
    "state_md_freshness_warning_hours": $fresh_warn
  },
  "triggers": {
    "consolidate_on_session_end": $end_trigger,
    "consolidate_on_topic_boundary": $topic_trigger,
    "auto_restart_in_flight_subagents_blocked": $restart_block
  },
  "model_overrides": {}
}
EOF
}
