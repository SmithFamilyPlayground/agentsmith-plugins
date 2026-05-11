#!/usr/bin/env bash
# routes.sh — routes cache + bundled-default fallback CLI.
#
# Implements GetRoutes(slug?) (api spec §W.1) against a session-start
# cache, with bundled defaults (§8.2) as the svc-unreachable fallback.

set -euo pipefail

_API_SELF="${BASH_SOURCE[0]}"
while [ -h "$_API_SELF" ]; do
    _API_DIR="$(cd -P "$(dirname "$_API_SELF")" && pwd)"
    _API_SELF="$(readlink "$_API_SELF")"
    [[ "$_API_SELF" != /* ]] && _API_SELF="$_API_DIR/$_API_SELF"
done
API_CLI_DIR="$(cd -P "$(dirname "$_API_SELF")" && pwd)"
API_PLUGIN_ROOT="$(cd -P "$API_CLI_DIR/.." && pwd)"
API_LIB_DIR="$API_PLUGIN_ROOT/lib"

api_die()  { printf 'routes: error: %s\n' "$*" >&2; exit 1; }
api_warn() { printf 'routes: warn: %s\n' "$*" >&2; }
api_usage() {
    cat <<'EOF'
routes.sh — routes cache + bundled-default fallback.

Usage:
  routes.sh get  [--slug <slug>] [--force-refresh]
                 (defaults --slug to TOD_AGENT_NAME or 'tod')
  routes.sh validate <path> [--slug <slug>]
                 (exits 0 if writable, non-zero otherwise)
  routes.sh refresh                  (phase-2b — hits svc; stubbed)

Env:
  TOD_AGENT_NAME       default slug
  CLAUDE_SESSION_ID    per-session cache discriminator
  TMPDIR               cache root (default /tmp)
  AGENT_PROJECT_SLUG   substituted for <project-slug> in jef's extras
EOF
}

# shellcheck disable=SC1091
. "$API_LIB_DIR/ids.sh"
# shellcheck disable=SC1091
. "$API_LIB_DIR/routes.sh"

routes_get_cmd() {
    local slug="" force=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --slug) slug="$2"; shift 2 ;;
            --force-refresh) force=1; shift ;;
            -h|--help) api_usage; return 0 ;;
            *) api_die "get: unknown arg: $1" ;;
        esac
    done
    if [ -z "$slug" ]; then
        slug="${TOD_AGENT_NAME:-tod}"
    fi
    api_validate_roster_slug routes "$slug"

    local snapshot=""
    if [ "$force" -eq 0 ]; then
        snapshot="$(api_routes_cache_read "$slug" 2>/dev/null || true)"
    fi
    if [ -z "$snapshot" ]; then
        # Phase-2a: svc round-trip is not implemented. Fall back to the
        # bundled defaults. Phase-2b will hit /api/v1/routes/<slug>.
        snapshot="$(api_routes_snapshot_from_default "$slug")"
        api_routes_cache_write "$slug" "$snapshot" >/dev/null
    fi
    printf '%s\n' "$snapshot"
}

routes_validate_cmd() {
    local slug="" path=""
    local seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --slug) slug="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            -*) api_die "validate: unknown flag: $1" ;;
            *) path="$1"; seen=1; shift ;;
        esac
    done
    if [ "$seen" -eq 0 ]; then
        api_die "validate: path required"
    fi
    if [ -z "$slug" ]; then
        slug="${TOD_AGENT_NAME:-tod}"
    fi
    api_validate_roster_slug routes "$slug"
    if api_routes_validate_path "$slug" "$path"; then
        printf 'ok\n'
        return 0
    else
        return 1
    fi
}

routes_refresh_cmd() {
    api_warn "refresh: phase-2a stub — svc round-trip not implemented (use 'get --force-refresh' for cache rebuild from bundled defaults)"
    return 0
}

main() {
    if [ "$#" -eq 0 ]; then
        api_usage
        exit 0
    fi
    local subcmd="$1"
    shift
    case "$subcmd" in
        get)      routes_get_cmd "$@" ;;
        validate) routes_validate_cmd "$@" ;;
        refresh)  routes_refresh_cmd "$@" ;;
        help|-h|--help) api_usage ;;
        *) api_die "unknown subcommand '$subcmd' (try 'routes.sh help')" ;;
    esac
}

main "$@"
