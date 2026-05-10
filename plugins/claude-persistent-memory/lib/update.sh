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
    #
    # Defensive parse: must be exactly three `/`-separated segments and
    # each segment must be a safe slug. `read -r` with three vars puts
    # everything-after-the-second-/ into `id`, so a hostile id like
    # `<slot>/<kind>/../../etc/shadow` would slip through without the
    # explicit `..`/`/` rejection in _cpm_validate_id_segment. See
    # Jax review on PR #12 (HIGH-1).
    local slot kind id
    IFS='/' read -r slot kind id <<EOF
$memory_id
EOF
    if [ -z "$slot" ] || [ -z "$kind" ] || [ -z "$id" ]; then
        cpm_die "update: malformed memory_id '$memory_id' (expected <slot>/<kind>/<id>)"
    fi
    # Reject any traversal-enabling content in any segment. We also
    # re-check that the memory_id had no extra `/`s past the second by
    # comparing the reassembly back to the input.
    _cpm_validate_id_segment update slot "$slot"
    _cpm_validate_id_segment update kind "$kind"
    _cpm_validate_id_segment update id   "$id"
    if [ "$slot/$kind/$id" != "$memory_id" ]; then
        cpm_die "update: malformed memory_id '$memory_id' (extra path separators)"
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
    # Place tmp file alongside the target so `mv` is a same-filesystem
    # rename (atomic) even when the vault lives on a different mount
    # than /tmp (fly: tmpfs /tmp + volume-backed project is plausible).
    # Also trap INT/TERM, not just EXIT — a Ctrl-C between mktemp and
    # mv would otherwise leak the temp file. Jax review LOW finding
    # on PR #12.
    local tmp
    tmp="$(mktemp -p "$(dirname "$abs_path")" .cpm-update.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT INT TERM

    # Pass `patch` via ENVIRON to avoid awk's `-v` escape-sequence
    # rewriting (Jax review HIGH-3). With `-v patch="$patch"`, awk
    # re-interprets `\n`, `\t`, `\\`, `\NNN`, etc. in the value, silently
    # corrupting any user content with literal backslashes (code snippets,
    # regex, JSON, Windows paths). ENVIRON bypasses that pass.
    # `now` is a controlled ISO timestamp (digits + `-:TZ`) so `-v` is
    # safe for it.
    CPM_UPDATE_PATCH="$patch" awk -v now="$now" '
        BEGIN { in_fm = 0; started_fm = 0; emitted_body = 0; patch = ENVIRON["CPM_UPDATE_PATCH"] }
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
    trap - EXIT INT TERM

    if [ "$(cpm_commit_shape "$vault")" = "git" ]; then
        cpm_git_commit "$vault" "cpm(update): $memory_id" "$abs_path"
    fi

    printf '%s\n' "$memory_id"
}

# Validate that a memory_id segment (slot, kind, or id) is a safe slug —
# nothing that could enable path traversal or shell metacharacter abuse.
#
# Allowed: letters, digits, dot (not leading), hyphen, underscore.
# Rejected: empty, `.`, `..`, anything containing `/` or other meta
# (handled by the positive regex), and any leading-dot form (which
# could mask hidden files / `..`).
#
# Args:
#   $1  subcommand label (for the error message)
#   $2  segment name (slot/kind/id — for the error message)
#   $3  the segment value
_cpm_validate_id_segment() {
    local where="$1" name="$2" value="$3"
    if [ -z "$value" ]; then
        cpm_die "$where: empty $name segment in memory_id"
    fi
    case "$value" in
        .|..) cpm_die "$where: $name segment must not be '.' or '..'" ;;
        .*)   cpm_die "$where: $name segment '$value' must not start with '.'" ;;
    esac
    # Positive pattern: only [A-Za-z0-9._-] from start to end.
    if ! printf '%s' "$value" | LC_ALL=C grep -qE '^[A-Za-z0-9._-]+$'; then
        cpm_die "$where: $name segment '$value' contains disallowed characters (allowed: [A-Za-z0-9._-])"
    fi
}
