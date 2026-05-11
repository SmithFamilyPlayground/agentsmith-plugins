#!/usr/bin/env bash
# dispatch.sh — Dispatch.Agent filesystem-queue rendezvous.
#
# Phase-2a MVP. With no svc, `dispatch agent` writes the request to a
# rendezvous file and emits the dispatch_id. The operator (or svc, when
# it lands) consumes the request and writes a sibling status file.
# Phase-2b POSTs to svc (api spec §6.2 / §7.4).
#
# Closed-set fix-concerns shape (api spec §A heuristic; Tod-asks-AgentSmith):
#   --role     <slug>          (closed-set: tod|agentsmith|jon|jax|jef|...)
#   --brief    <path or '-'>   (markdown brief; stdin if '-')
#   --spec-owner tod|jon       (defaults tod)
#   --interactive true|false   (defaults true)
#   --automerge true|false     (defaults true)
#
# Authorisation (spec §7.4): only Tod or the meta-agent may originate
# spawn.request. Phase-2a enforces this at the CLI layer (refuses other
# slugs). Phase-2b adds the HTTP-side 403 when svc is wired in.

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

api_die()  { printf 'dispatch: error: %s\n' "$*" >&2; exit 1; }
api_warn() { printf 'dispatch: warn: %s\n' "$*" >&2; }
api_usage() {
    cat <<'EOF'
dispatch.sh — Dispatch.Agent filesystem queue.

Usage:
  dispatch.sh agent --role <slug> --brief <path-or-->
                    [--spec-owner tod|jon]
                    [--interactive true|false]
                    [--automerge true|false]
                    [--requester <slug>]      (default $TOD_AGENT_NAME, must be tod or agentsmith)
                    [--queue-dir <dir>]       (default $TMPDIR/agentsmith-api/dispatch)

  dispatch.sh poll <dispatch_id> [--queue-dir <dir>]
                    Reads sibling .status.json if present; emits the body
                    or 'pending' if absent.

  dispatch.sh subscribe <dispatch_id>         (phase-2b — SSE; stubbed)

Env:
  TOD_AGENT_NAME    default requester slug
EOF
}

# shellcheck disable=SC1091
. "$API_LIB_DIR/ids.sh"

api_queue_dir() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    printf '%s/agentsmith-api/dispatch\n' "${TMPDIR:-/tmp}"
}

dispatch_agent_cmd() {
    local role="" brief="" spec_owner="jon" interactive="true" automerge="true"
    local requester="" queue_dir=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --role) role="$2"; shift 2 ;;
            --brief) brief="$2"; shift 2 ;;
            --spec-owner) spec_owner="$2"; shift 2 ;;
            --interactive) interactive="$2"; shift 2 ;;
            --automerge) automerge="$2"; shift 2 ;;
            --requester) requester="$2"; shift 2 ;;
            --queue-dir) queue_dir="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            *) api_die "agent: unknown arg: $1" ;;
        esac
    done
    if [ -z "$role" ]; then
        api_die "agent: --role required"
    fi
    if [ -z "$brief" ]; then
        api_die "agent: --brief required (path or '-')"
    fi
    if [ -z "$requester" ]; then
        requester="${TOD_AGENT_NAME:-tod}"
    fi
    api_validate_roster_slug dispatch "$role"
    api_validate_roster_slug dispatch "$requester"
    case "$spec_owner" in
        tod|jon) ;;
        *) api_die "agent: --spec-owner must be 'tod' or 'jon'" ;;
    esac
    case "$interactive" in true|false) ;; *) api_die "agent: --interactive must be true or false" ;; esac
    case "$automerge" in true|false) ;; *) api_die "agent: --automerge must be true or false" ;; esac
    # Authorisation per spec §7.4: only Tod (or the meta-agent) may
    # originate spawn.request.
    local req_base="${requester%-[0-9]*}"
    case "$req_base" in
        tod|agentsmith) ;;
        *) api_die "agent: requester '$requester' is not authorised to dispatch (only tod or agentsmith may originate spawn.request — api spec §7.4)" ;;
    esac

    local brief_body
    if [ "$brief" = "-" ]; then
        brief_body="$(cat -)"
    else
        if [ ! -f "$brief" ]; then
            api_die "agent: brief path '$brief' does not exist"
        fi
        brief_body="$(cat "$brief")"
    fi
    if [ -z "$brief_body" ]; then
        api_die "agent: brief is empty"
    fi

    local dispatch_id ts
    ts="$(api_iso_now)"
    dispatch_id="$(api_safe_id)"
    local qdir
    qdir="$(api_queue_dir "$queue_dir")"
    mkdir -p "$qdir"

    local target tmp
    target="$qdir/$dispatch_id.request.json"
    tmp="$(mktemp -p "$qdir" .dispatch.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT INT TERM

    # JSON-escape the brief body — handles the four bytes that bite in
    # practice for markdown text: backslash, double-quote, newline,
    # carriage-return, tab.
    #
    # KNOWN GAP (LOW-DEFERRED for phase-2b): other ASCII control
    # characters (0x00-0x1F except \n \r \t) are NOT escaped. JSON
    # technically requires them as \uXXXX. Phase-2b should swap this
    # path for a `jq -Rn --arg b "$brief_body" '$b'`-style proper
    # encoder when jq is added to the plugin's bin dependencies.
    # Markdown briefs in practice don't carry 0x00 / 0x1B / etc.
    api_json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\r'/\\r}"
        s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }
    local brief_escaped
    brief_escaped="$(api_json_escape "$brief_body")"

    cat > "$tmp" <<EOF
{
  "dispatch_id": "$dispatch_id",
  "type": "spawn.request",
  "ts": "$ts",
  "requester": "$requester",
  "role": "$role",
  "spec_owner": "$spec_owner",
  "interactive": $interactive,
  "automerge": $automerge,
  "brief": "$brief_escaped",
  "status": "pending"
}
EOF
    mv "$tmp" "$target"
    trap - EXIT INT TERM
    printf '%s\n' "$dispatch_id"
}

dispatch_poll_cmd() {
    local dispatch_id="" queue_dir=""
    local seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --queue-dir) queue_dir="$2"; shift 2 ;;
            -h|--help) api_usage; return 0 ;;
            -*) api_die "poll: unknown flag: $1" ;;
            *) dispatch_id="$1"; seen=1; shift ;;
        esac
    done
    if [ "$seen" -eq 0 ]; then
        api_die "poll: dispatch_id required"
    fi
    api_validate_id_segment poll dispatch_id "$dispatch_id"
    local qdir status_path request_path
    qdir="$(api_queue_dir "$queue_dir")"
    status_path="$qdir/$dispatch_id.status.json"
    request_path="$qdir/$dispatch_id.request.json"
    if [ -f "$status_path" ]; then
        cat "$status_path"
        return 0
    fi
    if [ -f "$request_path" ]; then
        # Request exists but no status yet — emit a minimal pending
        # snapshot rather than failing.
        cat <<EOF
{"dispatch_id":"$dispatch_id","status":"pending","note":"no status file present yet (request enqueued)"}
EOF
        return 0
    fi
    api_die "poll: dispatch_id '$dispatch_id' not found in queue ($qdir)"
}

dispatch_subscribe_cmd() {
    api_warn "subscribe: phase-2a stub — SSE streaming not implemented (use poll)"
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
        agent)     dispatch_agent_cmd "$@" ;;
        poll)      dispatch_poll_cmd "$@" ;;
        subscribe) dispatch_subscribe_cmd "$@" ;;
        help|-h|--help) api_usage ;;
        *) api_die "unknown subcommand '$subcmd' (try 'dispatch.sh help')" ;;
    esac
}

main "$@"
