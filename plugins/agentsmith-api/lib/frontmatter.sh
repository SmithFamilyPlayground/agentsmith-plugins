# shellcheck shell=bash
# lib/frontmatter.sh — YAML frontmatter helpers for the api Memory.*
# surface. Shape per api spec §V.2 (api-side frontmatter):
#
#   ---
#   type: <kind-derived: agent-rolling-state | summary | note | archive>
#   agent: <slot/caller-slug>
#   updated: <UTC ISO8601>
#   consolidated_through: <UTC ISO8601, kind=state only>
#   topic: <hint.topic when kind=summary>
#   privacy: <hint.privacy or family-internal default>
#   ---
#
# Sourced by lib/store.sh + lib/update.sh + lib/recall.sh. Caller must
# define api_die/api_warn.

# Map (kind) → frontmatter `type:` value, matching api spec §V.2.
api_type_for_kind() {
    case "$1" in
        state)   printf 'agent-rolling-state\n' ;;
        summary) printf 'summary\n' ;;
        note)    printf 'note\n' ;;
        archive) printf 'conversation\n' ;;
        *) api_die "frontmatter: unknown kind '$1'" ;;
    esac
}

# Extract a single top-level frontmatter field value from a file. Stops
# at the closing `---`. Empty result if not found. Matches cpm's
# _cpm_extract_frontmatter_field 1:1.
api_extract_frontmatter_field() {
    local file="$1" key="$2"
    if [ ! -f "$file" ]; then
        return 0
    fi
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

# Emit everything after the closing `---` of the frontmatter block.
# If no frontmatter, emit the whole file.
api_body_only() {
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

# Emit the first non-empty body paragraph of a file (everything after
# the closing `---` of frontmatter; first run of non-blank lines).
# Truncates to 240 chars for the summary view.
api_first_paragraph() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; started_fm = 0; past_fm = 0; in_para = 0; buf = "" }
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
