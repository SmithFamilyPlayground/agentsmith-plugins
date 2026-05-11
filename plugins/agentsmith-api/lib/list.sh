# shellcheck shell=bash
# lib/list.sh — Memory.List implementation against the AgentSmith vault.

api_list() {
    local vault="$1" slot="$2" filter="$3"
    api_validate_id_segment list slot "$slot"
    api_validate_roster_slug list "$slot"

    local slot_dir
    slot_dir="$(api_slot_dir "$vault" "$slot")"
    if [ ! -d "$slot_dir" ]; then
        api_die "list: slot '$slot' does not exist under $vault"
    fi

    local f mid lower_filter
    if [ -n "$filter" ]; then
        lower_filter="$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"
    else
        lower_filter=""
    fi

    while IFS= read -r -d '' f; do
        mid="$(api_extract_frontmatter_field "$f" memory_id)"
        if [ -z "$mid" ]; then
            continue
        fi
        if [ -n "$lower_filter" ]; then
            local lower_mid
            lower_mid="$(printf '%s' "$mid" | tr '[:upper:]' '[:lower:]')"
            case "$lower_mid" in
                *"$lower_filter"*) ;;
                *) continue ;;
            esac
        fi
        printf '%s\n' "$mid"
    done < <(find "$slot_dir" -type f -name '*.md' -print0 2>/dev/null | sort -z)
}
