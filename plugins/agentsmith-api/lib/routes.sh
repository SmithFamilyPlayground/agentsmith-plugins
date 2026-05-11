# shellcheck shell=bash
# lib/routes.sh — routes table (bundled fallback) + cache read/write.
#
# Per api spec §A + §W.3, the api plugin caches routes at session start
# and serves them locally for the rest of the session. svc-unreachable
# is a first-class path: when no cache exists, fall back to the bundled
# defaults. The defaults match spec §8.2 verbatim.
#
# Cache location: ${TMPDIR:-/tmp}/agentsmith-api/<agent>-<session_id>.routes.json
# Atomic writes: temp file under the same dir + os.replace (mv).
#
# Caller must define api_die/api_warn.

# Bundled default routes. Each line is `<slug>:<default_path>:<extras>`
# where extras is a comma-separated list of additional allowed paths.
# Extras may contain `<project-slug>` as a placeholder for the
# `$AGENT_PROJECT_SLUG` env var (spec §8.2 jef row).
api_routes_bundled_defaults() {
    cat <<'EOF'
tod:10_agents/tod/:secondbrain/memory/tod/
agentsmith::secondbrain/memory/agentsmith/
jon:10_agents/jon/:
jax:10_agents/jax/:
jef:10_agents/jef/:20_projects/<project-slug>/
EOF
    # sam/amy/ema deferred — spec §8.4 — no routes defined.
}

# Read the bundled-default route line for a slug. Slug is the bare role
# OR a suffix-instance form (jef-2, jon-3). Suffix-instance inherits the
# base role's routes.
#
# Emits the route line on stdout (`<slug>:<default>:<extras>`); empty on
# unknown slug.
api_routes_default_for_slug() {
    local slug="$1"
    local base
    # Allow only [A-Za-z]+(-[0-9]+)? — covered by api_validate_roster_slug
    # before we get here, but the suffix strip needs the regex shape.
    base="${slug%-[0-9]*}"
    api_routes_bundled_defaults | awk -F: -v slug="$slug" -v base="$base" '
        $1 == slug || $1 == base { print; exit }
    '
}

# Resolve the per-session cache path for an agent slug. Uses the
# CLAUDE_SESSION_ID env var when present (set by the Claude Code
# harness); falls back to `default` for ad-hoc CLI calls.
api_routes_cache_path() {
    local slug="$1"
    local cache_root="${TMPDIR:-/tmp}/agentsmith-api"
    local session="${CLAUDE_SESSION_ID:-default}"
    mkdir -p "$cache_root" 2>/dev/null || true
    printf '%s/%s-%s.routes.json\n' "$cache_root" "$slug" "$session"
}

# Write a routes-cache snapshot for a slug atomically. Body is JSON.
# Atomicity: temp file in the same directory + mv (same-fs rename).
# Trap on EXIT/INT/TERM so a Ctrl-C between write and rename doesn't
# leak the temp (Jax PR #12 LOW finding).
api_routes_cache_write() {
    local slug="$1" body="$2"
    local target tmp
    target="$(api_routes_cache_path "$slug")"
    local target_dir
    target_dir="$(dirname "$target")"
    mkdir -p "$target_dir"
    tmp="$(mktemp -p "$target_dir" .routes.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT INT TERM
    printf '%s\n' "$body" > "$tmp"
    mv "$tmp" "$target"
    trap - EXIT INT TERM
    printf '%s\n' "$target"
}

# Read the routes-cache snapshot for a slug. Emits the JSON body on
# stdout; returns non-zero if the cache is absent or unreadable.
api_routes_cache_read() {
    local slug="$1"
    local path
    path="$(api_routes_cache_path "$slug")"
    if [ -f "$path" ] && [ -r "$path" ]; then
        cat "$path"
        return 0
    fi
    return 1
}

# Build a routes-snapshot JSON object for a slug from the bundled
# defaults. Substitutes <project-slug> from $AGENT_PROJECT_SLUG when
# present. Schema:
#
#   {
#     "slug": "<agent-slug>",
#     "default_path": "<rel-path>",
#     "extras": ["<rel-path>", ...],
#     "source": "bundled-default",
#     "generated_at": "<UTC ISO8601>"
#   }
api_routes_snapshot_from_default() {
    local slug="$1"
    local line default_path extras
    line="$(api_routes_default_for_slug "$slug")"
    if [ -z "$line" ]; then
        # Unknown slug — emit a closed snapshot (no writable paths).
        printf '{"slug":"%s","default_path":"","extras":[],"source":"bundled-default-unknown","generated_at":"%s"}\n' \
            "$slug" "$(api_iso_now)"
        return 0
    fi
    default_path="$(printf '%s' "$line" | awk -F: '{print $2}')"
    extras="$(printf '%s' "$line" | awk -F: '{print $3}')"
    # Substitute <project-slug> placeholder.
    if [ -n "${AGENT_PROJECT_SLUG:-}" ]; then
        extras="${extras//<project-slug>/$AGENT_PROJECT_SLUG}"
    fi
    # Build JSON array from comma-separated list. Quote each element.
    local extras_json="["
    local first=1
    local IFS=','
    # shellcheck disable=SC2206  # intentional word-split on commas
    local items=($extras)
    unset IFS
    for item in "${items[@]}"; do
        [ -z "$item" ] && continue
        # Skip un-resolved placeholders (no AGENT_PROJECT_SLUG in env).
        case "$item" in
            *"<project-slug>"*) continue ;;
        esac
        if [ "$first" -eq 1 ]; then
            extras_json="$extras_json\"$item\""
            first=0
        else
            extras_json="$extras_json,\"$item\""
        fi
    done
    extras_json="$extras_json]"
    printf '{"slug":"%s","default_path":"%s","extras":%s,"source":"bundled-default","generated_at":"%s"}\n' \
        "$slug" "$default_path" "$extras_json" "$(api_iso_now)"
}

# Validate that `path` is within the writable set for `slug`. Returns 0
# if allowed, non-zero with a message on stderr otherwise.
#
# `path` is interpreted relative to the VAULT root. Both the snapshot's
# default_path and extras are prefix-matched.
#
# Cross-cutting denies (spec §8.3): `raw/` is immutable; `60_archive/` is
# frozen; writes to another agent's `10_agents/<other>/` slot are
# refused. These apply regardless of slug.
api_routes_validate_path() {
    local slug="$1" path="$2"
    # Strip leading `./` and any leading slash for prefix comparison.
    local rel="${path#./}"
    rel="${rel#/}"

    # Cross-cutting denies first.
    case "$rel" in
        raw/*|*/raw/*) printf 'api: write to raw/ refused (immutable per spec §8.3)\n' >&2; return 1 ;;
        60_archive/*) printf 'api: write to 60_archive/ refused (frozen per spec §8.3)\n' >&2; return 1 ;;
    esac
    # Cross-agent slot rejection (no agent writes another agent's slot).
    # Spec §8.3 cross-cutting: "Never write to another agent's
    # 10_agents/<other>/ slot." Applies REGARDLESS of slug — including
    # Tod and the meta-agent. Tod reads everywhere but does not write
    # other agents' slots; meta-agent does surgical work elsewhere in
    # the vault but is not exempt from this rule.
    if [[ "$rel" =~ ^10_agents/([^/]+)/ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local owner_base="${owner%-[0-9]*}"
        local slug_base="${slug%-[0-9]*}"
        if [ "$owner_base" != "$slug_base" ]; then
            printf 'api: cross-agent slot write refused (slug=%s tried 10_agents/%s/ — spec §8.3)\n' "$slug" "$owner" >&2
            return 1
        fi
    fi

    # Pull the snapshot for the slug — cache if present, else default.
    local snapshot default_path extras_raw
    if ! snapshot="$(api_routes_cache_read "$slug" 2>/dev/null)"; then
        snapshot="$(api_routes_snapshot_from_default "$slug")"
    fi
    # Very small JSON parser — pull fields with a single awk pass. We
    # tolerate spaces, commas inside the extras array. The snapshot is
    # always produced by api_routes_snapshot_from_default (or written
    # in the same shape by routes.sh get), so the format is controlled.
    default_path="$(printf '%s' "$snapshot" | awk -F'"default_path":"' 'NF>1{split($2,a,"\""); print a[1]; exit}')"
    extras_raw="$(printf '%s' "$snapshot" | awk -F'"extras":\\[' 'NF>1{split($2,a,"]"); print a[1]; exit}')"

    # Build the allow-list: default + each extras item (commas separated, quoted).
    local allowed=()
    if [ -n "$default_path" ]; then
        allowed+=("$default_path")
    fi
    # extras_raw is `"path1","path2"` — strip quotes, split on `","`.
    if [ -n "$extras_raw" ]; then
        local stripped="$extras_raw"
        stripped="${stripped#\"}"
        stripped="${stripped%\"}"
        local IFS='|'
        # Convert `","` separators to `|` so the IFS split works cleanly
        # without touching commas embedded in path names (which we
        # don't expect, but be robust).
        local normalised="${stripped//\",\"/|}"
        # shellcheck disable=SC2206
        local parts=($normalised)
        unset IFS
        for p in "${parts[@]}"; do
            [ -z "$p" ] && continue
            allowed+=("$p")
        done
    fi

    # Meta-agent special case: vault root is the default (per spec §8.2).
    # Treat empty default_path + slug=agentsmith as "vault root writable",
    # which means ANY path that hasn't been crossed-out above is OK.
    if [ "$slug" = "agentsmith" ] && [ -z "$default_path" ]; then
        return 0
    fi

    # Tod also has implicit broad-read; for writes we still respect his
    # explicit allow-list (10_agents/tod/ + secondbrain/memory/tod/).
    # No special case here.

    # Prefix-match against the allow-list.
    local prefix
    for prefix in "${allowed[@]}"; do
        [ -z "$prefix" ] && continue
        # Normalise: trailing slash on the allowed prefix means "this dir
        # and below". No trailing slash means "this exact path".
        case "$prefix" in
            */)
                case "$rel" in
                    "$prefix"*) return 0 ;;
                esac
                ;;
            *)
                if [ "$rel" = "$prefix" ]; then return 0; fi
                ;;
        esac
    done

    printf 'api: path %s outside allowed routes for %s (allowed: %s)\n' \
        "$path" "$slug" "${allowed[*]}" >&2
    return 1
}
