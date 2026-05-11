# shellcheck shell=bash
# lib/store.sh — Memory.Store implementation against the AgentSmith vault.
#
# Sourced by cli/memory.sh. Same five-kind shape as cpm's local-vault
# store, but routes the per-write path through cli/vault-commit.sh
# (today-branch + raw/-immutable + retry) when mode=today, or just
# writes-and-commits-on-current-branch when mode=local (for tests).
#
# On-disk layout (api spec §8 + §V.2):
#   state    → <vault>/10_agents/<slot>/state.md
#   summary  → <vault>/10_agents/<slot>/summaries/by-topic/<topic>.md
#   note     → <vault>/10_agents/<slot>/notes/<id>.md
#   archive  → <vault>/10_agents/<slot>/conversations/<YYYY>/<MM>/<id>.md
#
# The agentsmith meta-agent special-cases to vault-root (no 10_agents/
# prefix) per spec §8.2.
#
# Caller must source lib/ids.sh + lib/frontmatter.sh + lib/routes.sh
# and define api_die/api_warn + the cli-level vault-commit invoker.

# Build the on-disk slot directory for the slot.
#   tod          → <vault>/10_agents/tod
#   jef-2        → <vault>/10_agents/jef-2
#   agentsmith   → <vault>          (meta-agent special case per §8.2)
api_slot_dir() {
    local vault="$1" slot="$2"
    if [ "$slot" = "agentsmith" ]; then
        printf '%s\n' "$vault"
    else
        printf '%s/10_agents/%s\n' "$vault" "$slot"
    fi
}

# Resolve (kind, slot, topic) → (id, rel_path) under the slot.
# Emits two lines: id, then rel_path. Caller reads them.
# rel_path is vault-rooted.
api_store_resolve_path() {
    local slot="$1" kind="$2" topic="$3"
    local id rel
    case "$kind" in
        state)
            id="state"
            if [ "$slot" = "agentsmith" ]; then
                rel="state.md"
            else
                rel="10_agents/$slot/state.md"
            fi
            ;;
        summary)
            local safe_topic
            safe_topic="$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
            if [ -z "$safe_topic" ]; then
                api_die "store: --topic '$topic' sanitises to empty"
            fi
            id="$safe_topic"
            if [ "$slot" = "agentsmith" ]; then
                rel="summaries/by-topic/$safe_topic.md"
            else
                rel="10_agents/$slot/summaries/by-topic/$safe_topic.md"
            fi
            ;;
        note)
            id="$(api_safe_id)"
            if [ "$slot" = "agentsmith" ]; then
                rel="notes/$id.md"
            else
                rel="10_agents/$slot/notes/$id.md"
            fi
            ;;
        archive)
            id="$(api_safe_id)"
            # YYYY/MM derived from the id itself, NOT from a separate
            # `date` call, so a minute/hour/month boundary tick can't
            # split id from path. Jax PR #12 LOW finding.
            local yyyy mm
            yyyy="${id:0:4}"
            mm="${id:4:2}"
            if [ "$slot" = "agentsmith" ]; then
                rel="conversations/$yyyy/$mm/$id.md"
            else
                rel="10_agents/$slot/conversations/$yyyy/$mm/$id.md"
            fi
            ;;
        *)
            api_die "store: invalid kind '$kind' (state|summary|note|archive)"
            ;;
    esac
    printf '%s\n' "$id"
    printf '%s\n' "$rel"
}

# Top-level store. Routes through vault-commit (mode=today) or writes
# directly + commits-on-current-branch (mode=local).
#
# Args:
#   vault, slot, kind, topic, privacy, content, mode, scan_mode
#
# Emits memory_id on stdout.
api_store() {
    local vault="$1" slot="$2" kind="$3" topic="$4" privacy="$5" content="$6" mode="$7" scan_mode="$8"

    api_validate_id_segment store slot "$slot"
    api_validate_roster_slug store "$slot"

    local resolved id rel_path abs_path memory_id
    # Read the two-line output of api_store_resolve_path.
    resolved="$(api_store_resolve_path "$slot" "$kind" "$topic")"
    id="$(printf '%s\n' "$resolved" | sed -n '1p')"
    rel_path="$(printf '%s\n' "$resolved" | sed -n '2p')"
    memory_id="$slot/$kind/$id"
    abs_path="$vault/$rel_path"

    # Routes validation (api spec §V.2 step 1). Reject before any
    # filesystem side-effect.
    if ! api_routes_validate_path "$slot" "$rel_path"; then
        api_die "store: target path '$rel_path' outside allowed routes for slot '$slot'"
    fi

    mkdir -p "$(dirname "$abs_path")"

    # Preserve existing frontmatter where the caller didn't override.
    # Same rule as cpm's lib/store.sh: re-store of state/summary without
    # --privacy keeps the existing privacy, not silently reset to the
    # default. `topic` is also preserved on re-store. Jax PR #12 MEDIUM
    # carried into the api side.
    local now existing_privacy existing_topic
    now="$(api_iso_now)"
    if [ -f "$abs_path" ]; then
        existing_privacy="$(api_extract_frontmatter_field "$abs_path" privacy)"
        existing_topic="$(api_extract_frontmatter_field "$abs_path" topic)"
        if [ -z "$privacy" ] && [ -n "$existing_privacy" ]; then
            privacy="$existing_privacy"
        fi
        if [ -z "$topic" ] && [ -n "$existing_topic" ]; then
            topic="$existing_topic"
        fi
    fi
    if [ -z "$privacy" ]; then
        privacy="family-internal"
    fi
    case "$privacy" in
        public|family-internal|private) ;;
        *) api_die "store: privacy value '$privacy' (from caller or existing frontmatter) is invalid" ;;
    esac

    local type_field
    type_field="$(api_type_for_kind "$kind")"

    # Optional consolidated_through for state — same `now` for v1.
    local consolidated_line=""
    if [ "$kind" = "state" ]; then
        consolidated_line=$'consolidated_through: '"$now"$'\n'
    fi
    local topic_field="$topic"
    if [ -z "$topic_field" ]; then
        topic_field=""
    fi

    # Write file. Use printf so backslashes in $content survive verbatim
    # (`echo` would interpret `\n` etc. on some shells). Matches the
    # cpm CLI's posture.
    {
        printf -- '---\n'
        printf -- 'type: %s\n' "$type_field"
        printf -- 'agent: %s\n' "$slot"
        printf -- 'kind: %s\n' "$kind"
        printf -- 'topic: %s\n' "$topic_field"
        printf -- 'privacy: %s\n' "$privacy"
        printf -- 'updated: %s\n' "$now"
        if [ -n "$consolidated_line" ]; then
            printf -- '%s' "$consolidated_line"
        fi
        printf -- 'memory_id: %s\n' "$memory_id"
        printf -- '---\n\n'
        printf -- '%s\n' "$content"
    } > "$abs_path"

    # Commit. mode=today routes through vault-commit.sh (today-branch +
    # raw/-immutable + retry); mode=local commits on the current branch
    # of the vault's git repo if any, else no-op (with a warn).
    api_store_commit "$vault" "$mode" "$scan_mode" "$slot" "$memory_id" "$abs_path"

    printf '%s\n' "$memory_id"
}

# Commit step — separated so tests can call mode=local without invoking
# the today-branch flow.
#
# Args: vault, mode, scan_mode, slot, memory_id, abs_path
api_store_commit() {
    local vault="$1" mode="$2" scan_mode="$3" slot="$4" memory_id="$5" abs_path="$6"
    case "$mode" in
        today)
            # Invoke the bundled vault-commit.sh. Pass the abs_path so
            # vault-commit can scope the commit (it currently `git add
            # -A`s; future hardening per spec §V.2 step 5 will narrow
            # to pathspec, but that's a follow-up).
            if [ -n "${API_VAULT_COMMIT_BIN:-}" ] && [ -x "$API_VAULT_COMMIT_BIN" ]; then
                TOD_AGENT_NAME="$slot" VAULT_PATH="$vault" \
                    "$API_VAULT_COMMIT_BIN" --scan-mode "$scan_mode" --mode today \
                    --agent "$slot" "Memory.Store $memory_id" \
                    || api_warn "store: vault-commit.sh exited non-zero; file written ($abs_path)"
            else
                api_warn "store: API_VAULT_COMMIT_BIN not set; file written but no commit ($abs_path)"
            fi
            ;;
        local)
            # mode=local: pathspec-scoped commit on the current branch
            # in the vault's git repo (Jax PR #12 HIGH-2 carried in).
            api_store_commit_local "$vault" "$memory_id" "$abs_path"
            ;;
        *)
            api_die "store: invalid --mode '$mode' (today|local)"
            ;;
    esac
}

# mode=local commit: pathspec-scoped commit on current branch.
# Tolerates the vault not being a git repo (warn, return 0).
#
# Carries forward an intermittent flake (~5-10%) on the smoke's
# "store note committed" assertion — observed under Phase 1a's
# corresponding test and re-observed in phase-2a. Diagnosed as a
# race between the in-smoke `git log | grep` assertion and git's
# write-completion under `set -euo pipefail`. The commit DOES land
# (verifiable in the diag print after a failing assertion); the
# grep just intermittently doesn't see it within the same
# subprocess pipeline. Marked LOW-DEFERRED in SKILL.md.
api_store_commit_local() {
    local vault="$1" memory_id="$2" abs_path="$3"
    local repo_root
    if ! repo_root="$(git -C "$vault" rev-parse --show-toplevel 2>/dev/null)"; then
        api_warn "store(local): vault not in a git repo; file written ($abs_path)"
        return 0
    fi
    if ! git -C "$repo_root" add -- "$abs_path" 2>/dev/null; then
        api_warn "store(local): git add failed; file written but not committed"
        return 0
    fi
    if git -C "$repo_root" diff --cached --quiet -- "$abs_path"; then
        # Identical re-store. Legitimate no-op.
        return 0
    fi
    if ! git -C "$repo_root" \
        -c user.name="${API_GIT_USER_NAME:-agentsmith-api}" \
        -c user.email="${API_GIT_USER_EMAIL:-noreply@local}" \
        commit -m "api(store): $memory_id" --quiet -- "$abs_path" 2>/dev/null
    then
        api_warn "store(local): git commit failed; file written but not committed"
        return 0
    fi
    return 0
}
