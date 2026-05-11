# shellcheck shell=bash
# lib/store.sh — Memory.Store implementation for local-vault.
#
# Sourced by cli/local-vault.sh. Assumes the following globals are
# defined by the caller:
#   cpm_die       — function: print to stderr + exit 1
#   cpm_warn      — function: print to stderr + return 0
#   cpm_iso_now   — function: emit current UTC ISO timestamp on stdout
#   cpm_safe_id   — function: emit a timestamp-derived monotonic id
#   cpm_git_commit— function: best-effort commit
#   cpm_commit_shape — function: read commit_shape from config
#
# Resolved-path layout (see SKILL.md §"On-disk layout"):
#   state    → <vault>/<slot>/state.md                (canonical; overwrites)
#   summary  → <vault>/<slot>/topics/<topic>.md       (per-topic; overwrites)
#   note     → <vault>/<slot>/notes/<id>.md           (append-style; monotonic)
#   archive  → <vault>/<slot>/conversations/<YYYY>/<MM>/<id>.md
#
# Emits the resolved memory_id on stdout (matches the frontmatter field).

cpm_store() {
    local vault="$1" slot="$2" kind="$3" topic="$4" privacy="$5" content="$6"

    # Path-traversal defense: slot flows directly into the on-disk path
    # and into the emitted memory_id. Reject `..`, `/`, hidden-form, etc.
    # before constructing any path. (Defined in lib/update.sh.) See
    # Jax review on PR #12 (HIGH-1).
    _cpm_validate_id_segment store slot "$slot"

    local id rel_path abs_path memory_id slot_dir
    slot_dir="$vault/$slot"
    if [ ! -d "$slot_dir" ]; then
        cpm_die "slot '$slot' does not exist under $vault (run 'local-vault init --identity $slot')"
    fi

    case "$kind" in
        state)
            id="state"
            rel_path="$slot/state.md"
            ;;
        summary)
            # Sanitise topic: lowercase, replace non-alnum with '-'.
            local safe_topic
            safe_topic="$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
            if [ -z "$safe_topic" ]; then
                cpm_die "store: --topic '$topic' sanitises to empty"
            fi
            id="$safe_topic"
            rel_path="$slot/topics/$safe_topic.md"
            ;;
        note)
            id="$(cpm_safe_id)"
            rel_path="$slot/notes/$id.md"
            ;;
        archive)
            id="$(cpm_safe_id)"
            # Derive YYYY/MM from the id (which embeds the same UTC
            # timestamp cpm_safe_id minted), NOT from a separate `date`
            # call. The id format is `<YYYYMMDDTHHMMSSZ>-<rand>` — see
            # cpm_safe_id in cli/local-vault.sh. A separate `date -u`
            # call here would otherwise let a minute/hour/month
            # boundary slip between the two reads and route the file
            # into a YYYY/MM directory that the id doesn't reference;
            # update.sh's id-recovery slicing would then look in the
            # wrong place. Jax review LOW finding on PR #12.
            local yyyy mm
            yyyy="${id:0:4}"
            mm="${id:4:2}"
            mkdir -p "$slot_dir/conversations/$yyyy/$mm"
            rel_path="$slot/conversations/$yyyy/$mm/$id.md"
            ;;
        *)
            cpm_die "store: invalid kind '$kind'"
            ;;
    esac

    memory_id="$slot/$kind/$id"
    abs_path="$vault/$rel_path"
    mkdir -p "$(dirname "$abs_path")"

    # Preserve existing frontmatter where the caller didn't override it
    # (Jax review MEDIUM). Re-storing a state.md or summary without
    # passing --privacy must NOT silently reset privacy to the default
    # "family-internal"; same for topic (which is also caller-supplied
    # but optional). `created` is always carried forward when present.
    # Note: `privacy` is the empty string when the caller did not pass
    # --privacy on the command line (sentinel from cpm_store_cmd).
    local now created
    now="$(cpm_iso_now)"
    if [ -f "$abs_path" ]; then
        created="$(_cpm_extract_frontmatter_field "$abs_path" created)"
        if [ -z "$created" ]; then
            created="$now"
        fi
        if [ -z "$privacy" ]; then
            privacy="$(_cpm_extract_frontmatter_field "$abs_path" privacy)"
        fi
        if [ -z "$topic" ]; then
            topic="$(_cpm_extract_frontmatter_field "$abs_path" topic)"
        fi
    else
        created="$now"
    fi
    # Apply defaults for anything still empty (first-store path, or
    # re-store of a file whose existing frontmatter is empty for the
    # field).
    if [ -z "$privacy" ]; then
        privacy="family-internal"
    fi
    # Final privacy validation (defends against malformed existing
    # frontmatter feeding back into the writer).
    case "$privacy" in
        public|family-internal|private) ;;
        *) cpm_die "store: privacy value '$privacy' (from existing frontmatter or caller) is invalid" ;;
    esac

    # Frontmatter envelope. Topic field is empty-string when absent
    # (rather than missing) so the schema is stable.
    local topic_field="$topic"
    if [ -z "$topic_field" ]; then
        topic_field=""
    fi

    {
        printf -- '---\n'
        printf -- 'type: cpm-%s\n' "$kind"
        printf -- 'slot: %s\n' "$slot"
        printf -- 'kind: %s\n' "$kind"
        printf -- 'topic: %s\n' "$topic_field"
        printf -- 'privacy: %s\n' "$privacy"
        printf -- 'created: %s\n' "$created"
        printf -- 'updated: %s\n' "$now"
        printf -- 'memory_id: %s\n' "$memory_id"
        printf -- '---\n\n'
        printf -- '%s\n' "$content"
    } > "$abs_path"

    if [ "$(cpm_commit_shape "$vault")" = "git" ]; then
        cpm_git_commit "$vault" "cpm(store): $memory_id" "$abs_path"
    fi

    printf '%s\n' "$memory_id"
}

# Extract a single top-level frontmatter field value from a file.
# Stops at the closing `---`. Empty result if not found.
_cpm_extract_frontmatter_field() {
    local file="$1" key="$2"
    awk -v key="$key" '
        BEGIN { in_fm = 0; started = 0 }
        /^---[[:space:]]*$/ {
            if (!started) { in_fm = 1; started = 1; next }
            if (in_fm) { in_fm = 0; exit }
        }
        in_fm {
            line = $0
            n = index(line, ":")
            if (n == 0) next
            k = substr(line, 1, n - 1)
            v = substr(line, n + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (k == key) { print v; exit }
        }
    ' "$file"
}
