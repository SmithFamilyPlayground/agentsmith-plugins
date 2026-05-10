# shellcheck shell=bash
# lib/recall.sh — Memory.Recall implementation for local-vault.
#
# Phase-1a uses simple grep-based matching against body + frontmatter
# of all files under <vault>/<slot>/. Smarter semantic recall is
# deferred — the spec puts recall in a subagent surface (Layer B),
# not in the CLI itself.
#
# Walks the vault fresh on every call — per cpm spec §4 +
# overview rev 3 §8.2 (vault is source of truth; no warm caches).
#
# Scopes:
#   summary       — for each matching file, emit `<memory_id>\t<first_paragraph>`.
#   all-by-topic  — for each matching file, emit the entire file body
#                   (without the frontmatter envelope), delimited by `---`.

cpm_recall() {
    local vault="$1" slot="$2" scope="$3" query="$4"
    local slot_dir="$vault/$slot"
    if [ ! -d "$slot_dir" ]; then
        cpm_die "slot '$slot' does not exist under $vault"
    fi
    if [ -z "$query" ]; then
        cpm_die "recall: empty query"
    fi

    # Collect candidate files. Restrict to .md to avoid hits in
    # consolidation-log/<ts>.json etc. (phase-1b directories — not
    # present in phase-1a but safer to scope tightly now).
    local matches
    matches="$(grep -ril --include='*.md' --fixed-strings -- "$query" "$slot_dir" 2>/dev/null || true)"
    if [ -z "$matches" ]; then
        printf 'local-vault: no matches for: %s\n' "$query" >&2
        return 0
    fi

    if [ "$scope" = "summary" ]; then
        local f
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local mid first
            mid="$(_cpm_extract_frontmatter_field "$f" memory_id)"
            if [ -z "$mid" ]; then
                # Fall back to a relative path display if frontmatter missing.
                mid="${f#"$vault/"}"
            fi
            first="$(_cpm_first_paragraph "$f")"
            printf '%s\t%s\n' "$mid" "$first"
        done <<< "$matches"
        return 0
    fi

    if [ "$scope" = "all-by-topic" ]; then
        local first_match=1
        local f
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if [ "$first_match" -eq 0 ]; then
                printf '\n---\n\n'
            fi
            first_match=0
            local mid
            mid="$(_cpm_extract_frontmatter_field "$f" memory_id)"
            if [ -z "$mid" ]; then
                mid="${f#"$vault/"}"
            fi
            printf '# %s\n\n' "$mid"
            _cpm_body_only "$f"
        done <<< "$matches"
        return 0
    fi

    cpm_die "recall: invalid scope '$scope'"
}

# Emit the first non-empty body paragraph of a file (everything after
# the closing `---` of frontmatter; first run of non-blank lines).
# Truncates to 240 chars for the summary view.
_cpm_first_paragraph() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; started_fm = 0; past_fm = 0; in_para = 0 }
        /^---[[:space:]]*$/ {
            if (!started_fm) { in_fm = 1; started_fm = 1; next }
            if (in_fm) { in_fm = 0; past_fm = 1; next }
        }
        in_fm { next }
        !past_fm { past_fm = 1 }
        {
            if ($0 ~ /^[[:space:]]*$/) {
                if (in_para) exit
                next
            }
            if (!in_para) { in_para = 1 }
            line = $0
            gsub(/[[:cntrl:]]/, " ", line)
            buf = (buf == "" ? line : buf " " line)
        }
        END {
            if (length(buf) > 240) buf = substr(buf, 1, 237) "..."
            print buf
        }
    ' "$file"
}

# Emit everything after the closing `---` of the frontmatter block.
# If no frontmatter, emit the whole file.
_cpm_body_only() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; started_fm = 0; past_fm = 0 }
        /^---[[:space:]]*$/ {
            if (!started_fm) { in_fm = 1; started_fm = 1; next }
            if (in_fm) { in_fm = 0; past_fm = 1; next }
        }
        in_fm { next }
        { if (!started_fm) past_fm = 1; if (past_fm) print }
    ' "$file"
}
