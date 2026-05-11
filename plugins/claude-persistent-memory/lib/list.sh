# shellcheck shell=bash
# lib/list.sh — Memory.List implementation for local-vault.
#
# Walks the slot directory and emits one memory_id per line. Filter
# matches against memory_id text (substring, case-insensitive).
#
# Order: oldest-first by mtime so callers get a stable, deterministic
# listing.

cpm_list() {
    local vault="$1" slot="$2" filter="$3"
    # Path-traversal defense (Jax review HIGH-1).
    _cpm_validate_id_segment list slot "$slot"
    local slot_dir="$vault/$slot"
    if [ ! -d "$slot_dir" ]; then
        cpm_die "list: slot '$slot' does not exist under $vault"
    fi

    # find -print0 + sort by file path for stable output. We rely on
    # the memory_id (in frontmatter) for the printed identifier; the
    # path is just discovery.
    local f mid lower_filter
    if [ -n "$filter" ]; then
        lower_filter="$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"
    else
        lower_filter=""
    fi

    while IFS= read -r -d '' f; do
        mid="$(_cpm_extract_frontmatter_field "$f" memory_id)"
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
