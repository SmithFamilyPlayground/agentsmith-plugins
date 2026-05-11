# shellcheck shell=bash
# lib/update.sh — Memory.Update implementation against the AgentSmith vault.
#
# Resolves a memory_id (`<slot>/<kind>/<id>`) to a disk path under
# <vault>/10_agents/<slot>/ (or vault root for agentsmith), replaces the
# body wholesale with the patch, bumps `updated:` in frontmatter,
# commits via vault-commit.sh (mode=today) or local-commit (mode=local).
#
# Same path-traversal posture as cpm's lib/update.sh — explicit newline
# rejection + whole-string regex + reassembly-equality check. ENVIRON
# pass for the patch into awk so literal backslashes survive (Jax PR
# #12 HIGH-3 carried in).

api_update() {
    local vault="$1" memory_id="$2" patch="$3" mode="$4" scan_mode="$5"

    local slot kind id
    IFS='/' read -r slot kind id <<EOF
$memory_id
EOF
    if [ -z "$slot" ] || [ -z "$kind" ] || [ -z "$id" ]; then
        api_die "update: malformed memory_id '$memory_id' (expected <slot>/<kind>/<id>)"
    fi
    api_validate_id_segment update slot "$slot"
    api_validate_id_segment update kind "$kind"
    api_validate_id_segment update id   "$id"
    if [ "$slot/$kind/$id" != "$memory_id" ]; then
        api_die "update: malformed memory_id '$memory_id' (extra path separators)"
    fi
    api_validate_roster_slug update "$slot"

    local rel_path abs_path
    case "$kind" in
        state)
            if [ "$slot" = "agentsmith" ]; then
                rel_path="state.md"
            else
                rel_path="10_agents/$slot/state.md"
            fi
            ;;
        summary)
            if [ "$slot" = "agentsmith" ]; then
                rel_path="summaries/by-topic/$id.md"
            else
                rel_path="10_agents/$slot/summaries/by-topic/$id.md"
            fi
            ;;
        note)
            if [ "$slot" = "agentsmith" ]; then
                rel_path="notes/$id.md"
            else
                rel_path="10_agents/$slot/notes/$id.md"
            fi
            ;;
        archive)
            local yyyy mm
            yyyy="${id:0:4}"
            mm="${id:4:2}"
            if [ "$slot" = "agentsmith" ]; then
                rel_path="conversations/$yyyy/$mm/$id.md"
            else
                rel_path="10_agents/$slot/conversations/$yyyy/$mm/$id.md"
            fi
            ;;
        *) api_die "update: unknown kind '$kind' in memory_id" ;;
    esac
    abs_path="$vault/$rel_path"
    if [ ! -f "$abs_path" ]; then
        api_die "update: memory_id '$memory_id' resolves to '$abs_path' which does not exist"
    fi

    # Routes validation (defence-in-depth — caller may have crafted a
    # memory_id whose slot is allowed but whose kind targets a path
    # outside the writable set).
    if ! api_routes_validate_path "$slot" "$rel_path"; then
        api_die "update: target path '$rel_path' outside allowed routes for slot '$slot'"
    fi

    local now tmp
    now="$(api_iso_now)"
    # Temp file alongside the target so `mv` is same-filesystem atomic.
    # Trap EXIT/INT/TERM (Jax PR #12 LOW).
    tmp="$(mktemp -p "$(dirname "$abs_path")" .api-update.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT INT TERM

    # ENVIRON pass for the patch — avoids awk's `-v` escape-sequence
    # interpretation that would silently corrupt literal backslashes
    # (Jax PR #12 HIGH-3).
    API_UPDATE_PATCH="$patch" awk -v now="$now" '
        BEGIN { in_fm = 0; started_fm = 0; emitted_body = 0; patch = ENVIRON["API_UPDATE_PATCH"] }
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
                printf "---\n\n%s\n", patch
            }
        }
    ' "$abs_path" > "$tmp"
    mv "$tmp" "$abs_path"
    trap - EXIT INT TERM

    # Commit step (reuses store's commit helpers via the lib/store.sh
    # exports — store.sh is sourced before update.sh in cli/memory.sh).
    api_store_commit "$vault" "$mode" "$scan_mode" "$slot" "$memory_id" "$abs_path"

    printf '%s\n' "$memory_id"
}
