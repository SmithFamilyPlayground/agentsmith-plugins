#!/usr/bin/env bash
# memory.sh — Memory.* implementation against the AgentSmith vault.
#
# Phase-2a MVP. See plugins/agentsmith-api/skills/agentsmith-api/SKILL.md
# for the operator runbook, plugins/agentsmith-api/.claude-plugin/plugin.json
# for the plugin manifest, and docs/superpowers/specs/2026-05-08-agentsmith-
# comms-api-contract.md §M / §V (in the AgentSmith repo) for the contract.

set -euo pipefail

# --- Resolve own location so we can source lib/ files. -----------------------
# Follow symlinks so installation via symlink works.
_API_SELF="${BASH_SOURCE[0]}"
while [ -h "$_API_SELF" ]; do
    _API_DIR="$(cd -P "$(dirname "$_API_SELF")" && pwd)"
    _API_SELF="$(readlink "$_API_SELF")"
    [[ "$_API_SELF" != /* ]] && _API_SELF="$_API_DIR/$_API_SELF"
done
API_CLI_DIR="$(cd -P "$(dirname "$_API_SELF")" && pwd)"
API_PLUGIN_ROOT="$(cd -P "$API_CLI_DIR/.." && pwd)"
API_LIB_DIR="$API_PLUGIN_ROOT/lib"
export API_PLUGIN_ROOT API_CLI_DIR API_LIB_DIR

# --- Common helpers (sourced by lib/*). -------------------------------------

api_die() {
    printf 'memory: error: %s\n' "$*" >&2
    exit 1
}
api_warn() {
    printf 'memory: warn: %s\n' "$*" >&2
}
api_usage() {
    cat <<'EOF'
memory.sh — Memory.* implementation against the AgentSmith vault.

Usage:
  memory.sh store  [<content>] [--kind <k>] [--topic <t>] [--slot <s>]
                   [--privacy <p>] [--mode today|local] [--scan-mode full|skip]
                   [--vault <path>]
                   (content read from stdin if positional omitted or '-')
  memory.sh recall <query> [--scope summary|all-by-topic] [--slot <s>] [--vault <path>]
  memory.sh update <memory_id> [<patch>] [--mode today|local] [--scan-mode full|skip]
                   [--vault <path>]
                   (patch read from stdin if positional omitted or '-')
  memory.sh list   [--filter <f>] [--slot <s>] [--vault <path>]
  memory.sh config [--vault <path>]
  memory.sh help

Env:
  VAULT_PATH        default vault path (overrides default ~/.secondbrain)
  TOD_AGENT_NAME    default slot when --slot is not passed
  API_VAULT_COMMIT_BIN  override the vault-commit.sh used for mode=today
                        (default: <plugin-root>/cli/vault-commit.sh)

Modes:
  --mode today   AgentSmith default. Routes commits through vault-commit.sh
                 (today-branch + raw/-immutable + retry).
  --mode local   Test/standalone mode. Commits on the vault's current
                 branch (or no-op when not a git repo). Skips today-branch
                 ops entirely.

Scan modes (phase-2a stub):
  --scan-mode skip  Default. Skips the Haiku PII/secrets scan.
  --scan-mode full  Warns "Haiku scan not yet implemented" and proceeds.
                    Reserved for phase-2b.
EOF
}

# --- Source helpers. ---------------------------------------------------------
# shellcheck disable=SC1091
. "$API_LIB_DIR/ids.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/frontmatter.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/routes.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/store.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/update.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/recall.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/list.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/config.sh"

# --- Bundle the bundled vault-commit.sh as the default for mode=today. -----
if [ -z "${API_VAULT_COMMIT_BIN:-}" ]; then
    if [ -x "$API_CLI_DIR/vault-commit.sh" ]; then
        export API_VAULT_COMMIT_BIN="$API_CLI_DIR/vault-commit.sh"
    fi
fi

# Resolve effective vault path. Discovery: --vault > VAULT_PATH > ~/.secondbrain.
api_resolve_vault() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    if [ -n "${VAULT_PATH:-}" ]; then
        printf '%s\n' "$VAULT_PATH"
        return 0
    fi
    printf '%s\n' "$HOME/.secondbrain"
}

# Resolve effective slot. Defaults to $TOD_AGENT_NAME if --slot omitted;
# bails if that's also empty.
api_resolve_slot() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    if [ -n "${TOD_AGENT_NAME:-}" ]; then
        printf '%s\n' "$TOD_AGENT_NAME"
        return 0
    fi
    api_die "no slot resolved (pass --slot or set TOD_AGENT_NAME)"
}

# --- store subcommand. -----------------------------------------------------

api_store_cmd() {
    local content="" kind="note" topic="" slot="" privacy="" path=""
    local mode="today" scan_mode="skip"
    local positional_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --kind) kind="$2"; shift 2 ;;
            --topic) topic="$2"; shift 2 ;;
            --slot) slot="$2"; shift 2 ;;
            --privacy) privacy="$2"; shift 2 ;;
            --vault) path="$2"; shift 2 ;;
            --mode) mode="$2"; shift 2 ;;
            --scan-mode) scan_mode="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            --) shift; if [ "$#" -gt 0 ]; then content="$1"; positional_seen=1; shift; fi ;;
            -) content="-"; positional_seen=1; shift ;;
            -*) api_die "store: unknown flag: $1" ;;
            *) content="$1"; positional_seen=1; shift ;;
        esac
    done
    local vault
    vault="$(api_resolve_vault "$path")"
    if [ ! -d "$vault" ]; then
        api_die "store: vault '$vault' does not exist"
    fi
    slot="$(api_resolve_slot "$slot")"
    # Pull content from stdin if positional is '-' or absent.
    if [ "$positional_seen" -eq 0 ] || [ "$content" = "-" ]; then
        content="$(cat -)"
    fi
    case "$kind" in
        state|summary|note|archive) ;;
        *) api_die "store: invalid --kind '$kind' (state|summary|note|archive)" ;;
    esac
    if [ -n "$privacy" ]; then
        case "$privacy" in
            public|family-internal|private) ;;
            *) api_die "store: invalid --privacy '$privacy' (public|family-internal|private)" ;;
        esac
    fi
    if [ "$kind" = "summary" ] && [ -z "$topic" ]; then
        api_die "store: --topic is required when --kind=summary"
    fi
    case "$mode" in
        today|local) ;;
        *) api_die "store: invalid --mode '$mode' (today|local)" ;;
    esac
    case "$scan_mode" in
        skip) ;;
        full) api_warn "Haiku scan not yet implemented; treating --scan-mode full as skip (phase-2b)" ;;
        *) api_die "store: invalid --scan-mode '$scan_mode' (full|skip)" ;;
    esac
    api_store "$vault" "$slot" "$kind" "$topic" "$privacy" "$content" "$mode" "$scan_mode"
}

# --- update subcommand. ----------------------------------------------------

api_update_cmd() {
    local memory_id="" patch="" path="" mode="today" scan_mode="skip"
    local id_seen=0 patch_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --vault) path="$2"; shift 2 ;;
            --mode) mode="$2"; shift 2 ;;
            --scan-mode) scan_mode="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            -*) api_die "update: unknown flag: $1" ;;
            *)
                if [ "$id_seen" -eq 0 ]; then
                    memory_id="$1"; id_seen=1
                else
                    patch="$1"; patch_seen=1
                fi
                shift
                ;;
        esac
    done
    if [ "$id_seen" -eq 0 ]; then
        api_die "update: memory_id required"
    fi
    local vault
    vault="$(api_resolve_vault "$path")"
    if [ "$patch_seen" -eq 0 ] || [ "$patch" = "-" ]; then
        patch="$(cat -)"
    fi
    case "$mode" in
        today|local) ;;
        *) api_die "update: invalid --mode '$mode' (today|local)" ;;
    esac
    case "$scan_mode" in
        skip) ;;
        full) api_warn "Haiku scan not yet implemented; treating --scan-mode full as skip (phase-2b)" ;;
        *) api_die "update: invalid --scan-mode '$scan_mode' (full|skip)" ;;
    esac
    api_update "$vault" "$memory_id" "$patch" "$mode" "$scan_mode"
}

# --- recall subcommand. ----------------------------------------------------

api_recall_cmd() {
    local query="" scope="summary" slot="" path=""
    local positional_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --scope) scope="$2"; shift 2 ;;
            --slot) slot="$2"; shift 2 ;;
            --vault) path="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            -*) api_die "recall: unknown flag: $1" ;;
            *) query="$1"; positional_seen=1; shift ;;
        esac
    done
    if [ "$positional_seen" -eq 0 ]; then
        api_die "recall: query required"
    fi
    case "$scope" in
        summary|all-by-topic) ;;
        *) api_die "recall: invalid --scope '$scope' (summary|all-by-topic)" ;;
    esac
    local vault
    vault="$(api_resolve_vault "$path")"
    slot="$(api_resolve_slot "$slot")"
    api_recall "$vault" "$slot" "$scope" "$query"
}

# --- list subcommand. ------------------------------------------------------

api_list_cmd() {
    local filter="" slot="" path=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --filter) filter="$2"; shift 2 ;;
            --slot) slot="$2"; shift 2 ;;
            --vault) path="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            *) api_die "list: unknown arg: $1" ;;
        esac
    done
    local vault
    vault="$(api_resolve_vault "$path")"
    slot="$(api_resolve_slot "$slot")"
    api_list "$vault" "$slot" "$filter"
}

# --- config subcommand. ----------------------------------------------------

api_config_cmd() {
    local path=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --vault) path="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            *) api_die "config: unknown arg: $1" ;;
        esac
    done
    local vault
    vault="$(api_resolve_vault "$path")"
    api_config "$vault"
}

main() {
    if [ "$#" -eq 0 ]; then
        api_usage
        exit 0
    fi
    local subcmd="$1"
    shift
    case "$subcmd" in
        store)   api_store_cmd  "$@" ;;
        recall)  api_recall_cmd "$@" ;;
        update)  api_update_cmd "$@" ;;
        list)    api_list_cmd   "$@" ;;
        config)  api_config_cmd "$@" ;;
        help|-h|--help) api_usage ;;
        *) api_die "unknown subcommand '$subcmd' (try 'memory.sh help')" ;;
    esac
}

main "$@"
