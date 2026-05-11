# shellcheck shell=bash
# lib/config.sh — Memory.Config implementation.
#
# Returns JSON matching api spec §M.4. Same shape as cpm's Memory.Config
# so consumer code speaks to either backend uniformly. Phase-2a uses
# the bundled defaults verbatim; phase-2b will cache the svc Memory.Config
# payload and refresh on demand.

api_config() {
    # vault arg accepted for future phase-2b use (per-vault Memory.Config
    # overrides cached from svc). Phase-2a emits the bundled-default
    # payload regardless; suppress SC2034 by referencing the arg
    # explicitly.
    local vault="${1:-}"
    : "$vault"
    cat <<EOF
{
  "contract_version": "agentsmith-api/1.0",
  "backend": "agentsmith-vault",
  "backend_version": "agentsmith-api/0.1.0-phase2a",
  "thresholds": {
    "active_context_pct": 0.30,
    "idle_auto_minutes": 90,
    "idle_auto_context_pct": 0.40
  },
  "intervals": {
    "plan_usage_refresh_minutes": 5,
    "state_md_freshness_warning_hours": 24
  },
  "triggers": {
    "consolidate_on_session_end": true,
    "consolidate_on_topic_boundary": true,
    "auto_restart_in_flight_subagents_blocked": true
  },
  "model_overrides": {}
}
EOF
}
