#!/usr/bin/env bash
# local-vault — Memory.* implementation against a local project vault.
#
# Phase-1a MVP — see plugins/claude-persistent-memory/skills/.../SKILL.md
# for the operator runbook and plugins/claude-persistent-memory/.claude-plugin/
# plugin.json for the plugin manifest.
#
# Contract: cpm spec rev 2 §9 + api spec §M (paths in the AgentSmith repo
# under docs/superpowers/specs/).

set -euo pipefail

# --- Resolve own location so we can source lib/ files. -----------------------
# Follow symlinks so installation via symlink works.
_CPM_SELF="${BASH_SOURCE[0]}"
while [ -h "$_CPM_SELF" ]; do
    _CPM_DIR="$(cd -P "$(dirname "$_CPM_SELF")" && pwd)"
    _CPM_SELF="$(readlink "$_CPM_SELF")"
    [[ "$_CPM_SELF" != /* ]] && _CPM_SELF="$_CPM_DIR/$_CPM_SELF"
done
CPM_CLI_DIR="$(cd -P "$(dirname "$_CPM_SELF")" && pwd)"
CPM_PLUGIN_ROOT="$(cd -P "$CPM_CLI_DIR/.." && pwd)"
CPM_LIB_DIR="$CPM_PLUGIN_ROOT/lib"
export CPM_PLUGIN_ROOT CPM_CLI_DIR CPM_LIB_DIR

# --- Source helpers. ---------------------------------------------------------
# shellcheck disable=SC1091  # paths resolve at runtime via CPM_LIB_DIR
. "$CPM_LIB_DIR/store.sh"
# shellcheck disable=SC1091
. "$CPM_LIB_DIR/recall.sh"
# shellcheck disable=SC1091
. "$CPM_LIB_DIR/update.sh"
# shellcheck disable=SC1091
. "$CPM_LIB_DIR/list.sh"
# shellcheck disable=SC1091
. "$CPM_LIB_DIR/config.sh"

# --- Common helpers. ---------------------------------------------------------

cpm_die() {
    printf 'local-vault: error: %s\n' "$*" >&2
    exit 1
}

cpm_warn() {
    printf 'local-vault: warn: %s\n' "$*" >&2
}

cpm_usage() {
    cat <<'EOF'
local-vault — Memory.* backend against a local project vault.

Usage:
  local-vault init   [--path <dir>] [--identity <slug>]
  local-vault store  [<content>] [--kind <k>] [--topic <t>] [--slot <s>] [--privacy <p>]
                     [--path <dir>]
                     (content read from stdin if positional omitted or '-')
  local-vault recall <query> [--scope summary|all-by-topic] [--slot <s>] [--path <dir>]
  local-vault update <memory_id> [<patch>] [--path <dir>]
                     (patch read from stdin if positional omitted or '-')
  local-vault list   [--filter <f>] [--slot <s>] [--path <dir>]
  local-vault config [--path <dir>]
  local-vault help

Env:
  CPM_VAULT_PATH    default vault path (overrides discovery; --path overrides this)

Vault discovery order:
  --path arg > CPM_VAULT_PATH env > <cwd>/.claude-persistent-memory >
  walk up to first ancestor containing .claude-persistent-memory
EOF
}

# Compute the vault path used by all subcommands except `init`, which
# also writes the directory if missing.
#
# Discovery: --path > CPM_VAULT_PATH > cwd/.claude-persistent-memory >
#            walk up to first ancestor.
#
# Stdout: the resolved absolute path; exit non-zero with a message if
#         none found.
cpm_resolve_vault() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        # Canonicalise; allow missing for init.
        if [ -d "$explicit" ]; then
            (cd "$explicit" && pwd)
            return 0
        fi
        printf '%s\n' "$explicit"
        return 0
    fi
    if [ -n "${CPM_VAULT_PATH:-}" ]; then
        printf '%s\n' "$CPM_VAULT_PATH"
        return 0
    fi
    local dir
    dir="$(pwd)"
    while :; do
        if [ -d "$dir/.claude-persistent-memory" ]; then
            printf '%s\n' "$dir/.claude-persistent-memory"
            return 0
        fi
        local parent
        parent="$(dirname "$dir")"
        if [ "$parent" = "$dir" ]; then
            return 1
        fi
        dir="$parent"
    done
}

# Pull a value out of config.toml. Phase-1a uses a tiny parser
# (key=value, value possibly quoted; sections recognised but flat
# namespace inside). For phase-1a's small set of keys this is
# adequate; future revs may swap to a proper toml lib.
#
# Args:
#   $1  config file path
#   $2  section name (or '_root' for top-level)
#   $3  key
#   $4  default
cpm_config_get() {
    local file="$1" section="$2" key="$3" default="$4"
    if [ ! -f "$file" ]; then
        printf '%s\n' "$default"
        return 0
    fi
    awk -v section="$section" -v key="$key" -v default_val="$default" '
        BEGIN { in_section = (section == "_root"); found = 0 }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            line = $0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", line)
            in_section = (line == section)
            next
        }
        in_section {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            n = split(line, kv, "=")
            if (n < 2) next
            k = kv[1]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k != key) next
            v = line
            sub(/^[^=]*=/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            gsub(/^"|"$/, "", v)
            print v
            found = 1
            exit
        }
        END { if (!found) print default_val }
    ' "$file"
}

cpm_default_identity() {
    local vault="$1"
    cpm_config_get "$vault/config.toml" _root default_identity default
}

cpm_commit_shape() {
    local vault="$1"
    cpm_config_get "$vault/config.toml" local_vault commit_shape git
}

cpm_iso_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

cpm_safe_id() {
    # Timestamp-derived monotonic id. Compact, sortable.
    # 14-char UTC timestamp + 6-char random hex suffix. Two same-second
    # calls collide only on a 1-in-16M random hit; phase-1a single-writer
    # assumption (cpm spec §9.7) makes this acceptable. If multi-writer
    # local-vault is ever introduced, swap for a UUID.
    local ts rand
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    rand="$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 6 || true)"
    if [ -z "$rand" ]; then
        rand="$$"
    fi
    printf '%s-%s' "$ts" "$rand"
}

# Best-effort git commit of paths under the vault on the current
# branch. Only invoked when commit_shape = "git". Tolerates the
# vault not being inside a git repo by warning and returning 0
# (the file write already succeeded).
cpm_git_commit() {
    local vault="$1"
    local message="$2"
    shift 2
    # Find the enclosing git repo for the vault.
    local repo_root
    if ! repo_root="$(git -C "$vault" rev-parse --show-toplevel 2>/dev/null)"; then
        cpm_warn "vault not in a git repo; skipping commit (set commit_shape='none' in config.toml to silence)"
        return 0
    fi
    if [ "$#" -eq 0 ]; then
        cpm_warn "no paths passed to cpm_git_commit; skipping"
        return 0
    fi
    # Stage and commit. Fail soft — write already happened.
    if ! git -C "$repo_root" add -- "$@" 2>/dev/null; then
        cpm_warn "git add failed; file written but not committed"
        return 0
    fi
    if git -C "$repo_root" diff --cached --quiet -- "$@"; then
        # Nothing actually changed (e.g. identical re-store).
        return 0
    fi
    # Pathspec-scoped commit (Jax review HIGH-2). Without `-- "$@"`
    # this `git commit` would sweep any operator-pre-staged unrelated
    # files into the cpm commit message, silently. With the pathspec,
    # only the cpm-touched paths land in the new commit; pre-staged
    # other entries stay in the index for the operator's next commit.
    if ! git -C "$repo_root" \
        -c user.name="${CPM_GIT_USER_NAME:-claude-persistent-memory}" \
        -c user.email="${CPM_GIT_USER_EMAIL:-noreply@local}" \
        commit -m "$message" --quiet -- "$@" 2>/dev/null
    then
        cpm_warn "git commit failed; file written but not committed"
        return 0
    fi
    return 0
}

# --- Subcommand dispatch. ----------------------------------------------------

cpm_init() {
    local path="" identity=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --path) path="$2"; shift 2 ;;
            --identity) identity="$2"; shift 2 ;;
            -h|--help) cpm_usage; return 0 ;;
            *) cpm_die "init: unknown arg: $1" ;;
        esac
    done
    if [ -z "$path" ]; then
        path="$(pwd)/.claude-persistent-memory"
    fi
    if [ -z "$identity" ]; then
        identity="default"
    fi
    # Path-traversal defense (Jax review HIGH-1): --identity becomes
    # a directory under $path and a slot in every emitted memory_id.
    _cpm_validate_id_segment init identity "$identity"
    mkdir -p "$path/$identity/topics" "$path/$identity/notes" "$path/$identity/conversations"
    # Write a stub config.toml only if absent.
    if [ ! -f "$path/config.toml" ]; then
        # Decide commit_shape default: git if cwd is inside a git repo, else none.
        local shape="git"
        if ! git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1; then
            if ! git -C "$(dirname "$path")" rev-parse --show-toplevel >/dev/null 2>&1; then
                shape="none"
                cpm_warn "no enclosing git repo; defaulting commit_shape=none"
            fi
        fi
        cat > "$path/config.toml" <<EOF
# claude-persistent-memory — phase-1a local-vault config
# See plugins/claude-persistent-memory/skills/claude-persistent-memory/SKILL.md.

default_identity = "$identity"

[local_vault]
# "git"        — default; each Store/Update commits on the current branch.
# "git-branch" — TBD-phase-1b; writes land on a dedicated branch.
# "none"       — file-system writes only; no git involvement.
commit_shape = "$shape"
git_branch   = "claude-persistent-memory/today"   # only used when commit_shape = "git-branch"
git_user     = "claude-persistent-memory <noreply@local>"

[backend]
# Phase-1a is always local-vault. Phase-1c adds auto-detect of agentsmith-api.
type = "local-vault"

[thresholds]
active_context_pct      = 0.30
idle_auto_minutes       = 90
idle_auto_context_pct   = 0.40

[intervals]
plan_usage_refresh_minutes        = 5
state_md_freshness_warning_hours  = 24

[triggers]
consolidate_on_session_end          = true
consolidate_on_topic_boundary       = true
auto_restart_in_flight_subagents_blocked = true
EOF
    fi
    # Initialise state.md with empty sections if absent.
    local state_path="$path/$identity/state.md"
    if [ ! -f "$state_path" ]; then
        local now
        now="$(cpm_iso_now)"
        cat > "$state_path" <<EOF
---
type: cpm-state
slot: $identity
kind: state
topic:
privacy: family-internal
created: $now
updated: $now
memory_id: $identity/state/state
---

## Current focus

(empty — phase-1a init)

## Recent decisions

## Open threads

## Todos / breadcrumbs

## Stale-after
EOF
    fi
    printf '%s\n' "$path"
    if [ "$(cpm_commit_shape "$path")" = "git" ]; then
        cpm_git_commit "$path" "cpm(init): scaffold vault at $path (identity=$identity)" \
            "$path/config.toml" "$path/$identity/state.md"
    fi
}

cpm_store_cmd() {
    # NOTE on default sentinels: privacy and topic default to the empty
    # string here so cpm_store can distinguish "operator didn't pass
    # --privacy" (preserve existing on re-store; default to
    # family-internal on first-store) from "operator explicitly passed
    # --privacy family-internal" (always set). See Jax review MEDIUM.
    local content="" kind="note" topic="" slot="" privacy="" path=""
    local positional_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --kind) kind="$2"; shift 2 ;;
            --topic) topic="$2"; shift 2 ;;
            --slot) slot="$2"; shift 2 ;;
            --privacy) privacy="$2"; shift 2 ;;
            --path) path="$2"; shift 2 ;;
            -h|--help) cpm_usage; return 0 ;;
            --) shift; if [ "$#" -gt 0 ]; then content="$1"; positional_seen=1; shift; fi ;;
            -) content="-"; positional_seen=1; shift ;;
            -*) cpm_die "store: unknown flag: $1" ;;
            *) content="$1"; positional_seen=1; shift ;;
        esac
    done
    local vault
    vault="$(cpm_resolve_vault "$path")" || cpm_die "no vault found (run 'local-vault init' first)"
    if [ ! -f "$vault/config.toml" ]; then
        cpm_die "vault at $vault has no config.toml (run 'local-vault init')"
    fi
    if [ -z "$slot" ]; then
        slot="$(cpm_default_identity "$vault")"
    fi
    # Pull content from stdin if positional is '-' or absent.
    if [ "$positional_seen" -eq 0 ] || [ "$content" = "-" ]; then
        # Read all of stdin.
        content="$(cat -)"
    fi
    # Validate kind.
    case "$kind" in
        state|summary|note|archive) ;;
        *) cpm_die "store: invalid --kind '$kind' (state|summary|note|archive)" ;;
    esac
    # Empty privacy means "not set on the command line" — cpm_store
    # decides whether to fall back to the existing-frontmatter value
    # (re-store) or to the default (first-store).
    if [ -n "$privacy" ]; then
        case "$privacy" in
            public|family-internal|private) ;;
            *) cpm_die "store: invalid --privacy '$privacy' (public|family-internal|private)" ;;
        esac
    fi
    if [ "$kind" = "summary" ] && [ -z "$topic" ]; then
        cpm_die "store: --topic is required when --kind=summary"
    fi
    cpm_store "$vault" "$slot" "$kind" "$topic" "$privacy" "$content"
}

cpm_recall_cmd() {
    local query="" scope="summary" slot="" path=""
    local positional_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --scope) scope="$2"; shift 2 ;;
            --slot) slot="$2"; shift 2 ;;
            --path) path="$2"; shift 2 ;;
            -h|--help) cpm_usage; return 0 ;;
            -*) cpm_die "recall: unknown flag: $1" ;;
            *) query="$1"; positional_seen=1; shift ;;
        esac
    done
    if [ "$positional_seen" -eq 0 ]; then
        cpm_die "recall: query required"
    fi
    case "$scope" in
        summary|all-by-topic) ;;
        *) cpm_die "recall: invalid --scope '$scope' (summary|all-by-topic)" ;;
    esac
    local vault
    vault="$(cpm_resolve_vault "$path")" || cpm_die "no vault found (run 'local-vault init' first)"
    if [ -z "$slot" ]; then
        slot="$(cpm_default_identity "$vault")"
    fi
    cpm_recall "$vault" "$slot" "$scope" "$query"
}

cpm_update_cmd() {
    local memory_id="" patch="" path=""
    local id_seen=0 patch_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --path) path="$2"; shift 2 ;;
            -h|--help) cpm_usage; return 0 ;;
            -*) cpm_die "update: unknown flag: $1" ;;
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
        cpm_die "update: memory_id required"
    fi
    local vault
    vault="$(cpm_resolve_vault "$path")" || cpm_die "no vault found"
    if [ "$patch_seen" -eq 0 ] || [ "$patch" = "-" ]; then
        patch="$(cat -)"
    fi
    cpm_update "$vault" "$memory_id" "$patch"
}

cpm_list_cmd() {
    local filter="" slot="" path=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --filter) filter="$2"; shift 2 ;;
            --slot) slot="$2"; shift 2 ;;
            --path) path="$2"; shift 2 ;;
            -h|--help) cpm_usage; return 0 ;;
            *) cpm_die "list: unknown arg: $1" ;;
        esac
    done
    local vault
    vault="$(cpm_resolve_vault "$path")" || cpm_die "no vault found"
    if [ -z "$slot" ]; then
        slot="$(cpm_default_identity "$vault")"
    fi
    cpm_list "$vault" "$slot" "$filter"
}

cpm_config_cmd() {
    local path=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --path) path="$2"; shift 2 ;;
            -h|--help) cpm_usage; return 0 ;;
            *) cpm_die "config: unknown arg: $1" ;;
        esac
    done
    local vault
    if ! vault="$(cpm_resolve_vault "$path")"; then
        # No vault yet — emit pure defaults.
        vault=""
    fi
    cpm_config "$vault"
}

main() {
    if [ "$#" -eq 0 ]; then
        cpm_usage
        exit 0
    fi
    local subcmd="$1"
    shift
    case "$subcmd" in
        init)    cpm_init    "$@" ;;
        store)   cpm_store_cmd  "$@" ;;
        recall)  cpm_recall_cmd "$@" ;;
        update)  cpm_update_cmd "$@" ;;
        list)    cpm_list_cmd   "$@" ;;
        config)  cpm_config_cmd "$@" ;;
        help|-h|--help) cpm_usage ;;
        *) cpm_die "unknown subcommand '$subcmd' (try 'local-vault help')" ;;
    esac
}

main "$@"
