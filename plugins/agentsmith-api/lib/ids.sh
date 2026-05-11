# shellcheck shell=bash
# lib/ids.sh — shared id helpers + path-traversal-safe segment validation.
#
# Sourced by cli/memory.sh + cli/routes.sh + cli/dispatch.sh + by hooks
# that need to validate slugs. Assumes the caller defines:
#   api_die       — print to stderr + exit non-zero
#
# Self-contained otherwise — no other lib dependencies.

api_iso_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Timestamp-derived monotonic id. 14-char UTC timestamp + 6-char random
# hex suffix. Two same-second calls collide only on a 1-in-16M random
# hit; phase-2a single-writer-per-agent assumption (api spec §V.6 —
# concurrency arbitration deferred) makes this acceptable. Matches the
# cpm CLI's shape exactly so memory_ids round-trip 1:1 between backends.
api_safe_id() {
    local ts rand
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    rand="$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 6 || true)"
    if [ -z "$rand" ]; then
        rand="$$"
    fi
    printf '%s-%s' "$ts" "$rand"
}

# Validate that a memory_id segment (slot, kind, or id) is a safe slug —
# nothing that could enable path traversal or shell metacharacter abuse.
#
# Lifted from cpm's lib/update.sh _cpm_validate_id_segment (Jax PR #12
# HIGH-1 + HIGH-1b fixes). Keep this in lockstep with the cpm copy —
# the same path-traversal surface exists on the api side because
# memory_ids flow into the on-disk path under
# <vault>/10_agents/<slot>/... and into the emitted memory_id.
#
# Allowed:  [A-Za-z0-9._-]  end-to-end whole-string
# Rejected: empty, '.', '..', leading-dot, embedded newlines (LLM
#           output routinely carries stray newlines), anything outside
#           the positive class.
#
# Args:
#   $1  subcommand label (for the error message)
#   $2  segment name (slot/kind/id — for the error message)
#   $3  the segment value
api_validate_id_segment() {
    local where="$1" name="$2" value="$3"
    if [ -z "$value" ]; then
        api_die "$where: empty $name segment in memory_id"
    fi
    # Explicit newline rejection: clearer error than the regex would
    # give, and a belt-and-braces guard against any regex regression.
    case "$value" in
        *$'\n'*) api_die "$where: $name segment must not contain a newline" ;;
    esac
    case "$value" in
        .|..) api_die "$where: $name segment must not be '.' or '..'" ;;
        .*)   api_die "$where: $name segment '$value' must not start with '.'" ;;
    esac
    # Whole-string regex via bash `[[ =~ ]]` (NOT `grep -E ^...$` which
    # is line-oriented and bypassed by multiline values — Jax PR #12
    # HIGH-1b finding). LC_ALL=C pin so character classes don't pick up
    # locale-dependent extras.
    local _re_ok=0
    if ( LC_ALL=C; [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ); then
        _re_ok=1
    fi
    if [ "$_re_ok" -ne 1 ]; then
        api_die "$where: $name segment '$value' contains disallowed characters (allowed: [A-Za-z0-9._-])"
    fi
}

# Validate the family-roster slug — must match the closed-set in
# spec §8.2. Used by vault-commit.sh (slot validation) and
# dispatch.sh (role validation).
#
# Args:
#   $1  subcommand label (for the error message)
#   $2  the slug
api_validate_roster_slug() {
    local where="$1" slug="$2"
    api_validate_id_segment "$where" agent "$slug"
    case "$slug" in
        tod|agentsmith|jon|jax|jef) return 0 ;;
        sam|amy|ema)
            # Deferred per spec §8.4 — accept the slug but warn so the
            # operator knows the routes table doesn't carry them yet.
            api_warn "$where: slug '$slug' is deferred per spec §8.4 — no routes defined"
            return 0
            ;;
        *)
            # Suffix-form (concurrent instance): jef-2, jon-3.
            local base="${slug%-[0-9]*}"
            case "$base" in
                tod|agentsmith|jon|jax|jef|sam|amy|ema) return 0 ;;
                *) api_die "$where: unknown agent slug '$slug' (expected: tod|agentsmith|jon|jax|jef|sam|amy|ema or <role>-<N>)" ;;
            esac
            ;;
    esac
}
