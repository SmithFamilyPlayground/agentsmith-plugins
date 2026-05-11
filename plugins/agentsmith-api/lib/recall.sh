# shellcheck shell=bash
# lib/recall.sh — Memory.Recall implementation against the AgentSmith vault.
#
# Phase-2a uses fixed-string grep against body + frontmatter of all
# files under the slot directory. Smarter recall lives in cpm's Layer B
# subagent (api spec §M.7 / overview rev 3 §8.2: vault is source of
# truth; no warm caches).

api_recall() {
    local vault="$1" slot="$2" scope="$3" query="$4"
    api_validate_id_segment recall slot "$slot"
    api_validate_roster_slug recall "$slot"

    local slot_dir
    slot_dir="$(api_slot_dir "$vault" "$slot")"
    if [ ! -d "$slot_dir" ]; then
        api_die "recall: slot '$slot' does not exist under $vault"
    fi
    if [ -z "$query" ]; then
        api_die "recall: empty query"
    fi

    local matches
    matches="$(grep -ril --include='*.md' --fixed-strings -- "$query" "$slot_dir" 2>/dev/null || true)"
    if [ -z "$matches" ]; then
        printf 'api: no matches for: %s\n' "$query" >&2
        return 0
    fi

    if [ "$scope" = "summary" ]; then
        local f mid first
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            mid="$(api_extract_frontmatter_field "$f" memory_id)"
            if [ -z "$mid" ]; then
                mid="${f#"$vault/"}"
            fi
            first="$(api_first_paragraph "$f")"
            printf '%s\t%s\n' "$mid" "$first"
        done <<< "$matches"
        return 0
    fi

    if [ "$scope" = "all-by-topic" ]; then
        local first_match=1
        local f mid
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if [ "$first_match" -eq 0 ]; then
                printf '\n---\n\n'
            fi
            first_match=0
            mid="$(api_extract_frontmatter_field "$f" memory_id)"
            if [ -z "$mid" ]; then
                mid="${f#"$vault/"}"
            fi
            printf '# %s\n\n' "$mid"
            api_body_only "$f"
        done <<< "$matches"
        return 0
    fi

    api_die "recall: invalid scope '$scope' (summary|all-by-topic)"
}
