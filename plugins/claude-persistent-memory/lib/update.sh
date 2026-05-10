# shellcheck shell=bash
# lib/update.sh — Memory.Update implementation for local-vault.
#
# Resolves a memory_id (`<slot>/<kind>/<id>`) to a disk path, replaces
# the body wholesale with the given patch (phase-1a is "replace body";
# diff-style patches are a phase-1b concern), bumps `updated:` in
# frontmatter, and (in `git` shape) commits.
#
# Emits the (unchanged) memory_id on stdout.

cpm_update() {
    local vault="$1" memory_id="$2" patch="$3"

    # Resolve memory_id → relative path.
    # Format: <slot>/<kind>/<id>
    local slot kind id
    IFS='/' read -r slot kind id <<EOF
$memory_id
EOF
    if [ -z "$slot" ] || [ -z "$kind" ] || [ -z "$id" ]; then
        cpm_die "update: malformed memory_id '$memory_id' (expected <slot>/<kind>/<id>)"
    fi

    local rel_path abs_path
    case "$kind" in
        state)
            rel_path="$slot/state.md"
            ;;
        summary)
            rel_path="$slot/topics/$id.md"
            ;;
        note)
            rel_path="$slot/notes/$id.md"
            ;;
        archive)
            # Archive id was minted as <yyyymmddTHHMMSSZ>-<rand>. Recover YYYY/MM.
            local yyyy mm
            yyyy="${id:0:4}"
            mm="${id:4:2}"
            rel_path="$slot/conversations/$yyyy/$mm/$id.md"
            ;;
        *)
            cpm_die "update: unknown kind '$kind' in memory_id"
            ;;
    esac
    abs_path="$vault/$rel_path"
    if [ ! -f "$abs_path" ]; then
        cpm_die "update: memory_id '$memory_id' resolves to '$abs_path' which does not exist"
    fi

    # Pull existing frontmatter; rewrite body.
    local now
    now="$(cpm_iso_now)"
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    awk -v patch="$patch" -v now="$now" '
        BEGIN { in_fm = 0; started_fm = 0; emitted_body = 0 }
        /^---[[:space:]]*$/ {
            if (!started_fm) { in_fm = 1; started_fm = 1; print; next }
            if (in_fm) {
                in_fm = 0
                print
                printf "\n%s\n", patch
                emitted_body = 1
                exit
            }
        }
        in_fm {
            line = $0
            if (line ~ /^updated:/) {
                printf "updated: %s\n", now
                next
            }
            print
            next
        }
        END {
            if (!emitted_body) {
                # Frontmatter never closed — emit a fresh closing + body so the
                # file becomes well-formed.
                printf "---\n\n%s\n", patch
            }
        }
    ' "$abs_path" > "$tmp"
    mv "$tmp" "$abs_path"
    trap - EXIT

    if [ "$(cpm_commit_shape "$vault")" = "git" ]; then
        cpm_git_commit "$vault" "cpm(update): $memory_id" "$abs_path"
    fi

    printf '%s\n' "$memory_id"
}
