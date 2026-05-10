#!/usr/bin/env bash
# tests/smoke.sh — exercise every local-vault subcommand end-to-end.
#
# Creates a temporary git-tracked project, runs init/store/list/recall/
# update/config against it, asserts shape, cleans up. No external
# dependencies beyond bash + grep + awk + git.
#
# Usage: bash tests/smoke.sh
#
# Exit 0 = all assertions passed; non-zero with a printed assertion
# message otherwise.

set -euo pipefail

# Resolve plugin root from this script's location.
TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -P "$TESTS_DIR/.." && pwd)"
CLI="$PLUGIN_ROOT/cli/local-vault.sh"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    shift
    if "$@"; then
        printf '  PASS  %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$desc" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) printf '  PASS  %s\n' "$desc"; PASS=$((PASS + 1)) ;;
        *)
            printf '  FAIL  %s\n        expected substring: %s\n        got: %s\n' \
                "$desc" "$needle" "$haystack" >&2
            FAIL=$((FAIL + 1))
            ;;
    esac
}

# --- Setup. ------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# Make a fresh git repo so commit_shape=git works.
git init --quiet
git config user.email "smoke@test"
git config user.name  "smoke-test"
# Allow the test repo's identity to differ from the operator's global
# config without churn.

VAULT="$WORK/.claude-persistent-memory"

printf '\n=== init ===\n'

OUT="$("$CLI" init --identity smoke 2>&1)"
assert_contains "init prints vault path" "$VAULT" "$OUT"
assert "init creates config.toml"          test -f "$VAULT/config.toml"
assert "init creates slot dir"             test -d "$VAULT/smoke"
assert "init creates state.md"             test -f "$VAULT/smoke/state.md"
assert "init creates topics dir"           test -d "$VAULT/smoke/topics"
assert "init creates notes dir"            test -d "$VAULT/smoke/notes"
assert "init creates conversations dir"    test -d "$VAULT/smoke/conversations"
init_committed() { git -C "$WORK" log --oneline | grep -q "cpm(init):"; }
assert "init committed config + state"     init_committed

printf '\n=== config ===\n'

CONFIG_JSON="$("$CLI" config)"
assert_contains "config emits contract_version (api spec M.4)" '"contract_version": "agentsmith-api/1.0"' "$CONFIG_JSON"
assert_contains "config emits backend_version (diagnostics)"   '"backend_version":'      "$CONFIG_JSON"
assert_contains "config emits thresholds"                      '"active_context_pct":'   "$CONFIG_JSON"
assert_contains "config emits idle_auto_minutes"               '"idle_auto_minutes":'    "$CONFIG_JSON"
assert_contains "config emits triggers"                        '"triggers":'             "$CONFIG_JSON"
assert_contains "config reports local-vault backend"           '"backend": "local-vault"' "$CONFIG_JSON"

printf '\n=== store (note) ===\n'

NOTE_ID="$("$CLI" store "first note body" --kind note --slot smoke)"
assert_contains "store note returns memory_id" "smoke/note/" "$NOTE_ID"
NOTE_FILE="$VAULT/smoke/notes/$(echo "$NOTE_ID" | awk -F/ '{print $3}').md"
assert "store note wrote file"                 test -f "$NOTE_FILE"
NOTE_CONTENT="$(cat "$NOTE_FILE")"
assert_contains "note has frontmatter type"    "type: cpm-note"  "$NOTE_CONTENT"
assert_contains "note carries memory_id"       "memory_id: $NOTE_ID" "$NOTE_CONTENT"
assert_contains "note carries body"            "first note body" "$NOTE_CONTENT"
note_committed() { git -C "$WORK" log --oneline | grep -q "cpm(store): $NOTE_ID"; }
assert "store note committed"                  note_committed

printf '\n=== store (summary, requires topic) ===\n'

SUM_ID="$("$CLI" store "kickoff brief summary" --kind summary --topic kickoff --slot smoke)"
assert_contains "store summary returns memory_id" "smoke/summary/kickoff" "$SUM_ID"
SUM_FILE="$VAULT/smoke/topics/kickoff.md"
assert "store summary wrote file"          test -f "$SUM_FILE"
SUM_CONTENT="$(cat "$SUM_FILE")"
assert_contains "summary topic field set"  "topic: kickoff"  "$SUM_CONTENT"

# Topic sanitisation.
SUM2_ID="$("$CLI" store "second summary" --kind summary --topic 'Topic Two!!' --slot smoke)"
assert_contains "topic sanitised to slug" "smoke/summary/topic-two" "$SUM2_ID"
assert "sanitised summary file exists"     test -f "$VAULT/smoke/topics/topic-two.md"

printf '\n=== store (state — special, single canonical doc) ===\n'

STATE_ID="$(printf '## Current focus\n\nworking on smoke test\n' | "$CLI" store - --kind state --slot smoke)"
assert_contains "state id is canonical"   "smoke/state/state" "$STATE_ID"
STATE_CONTENT="$(cat "$VAULT/smoke/state.md")"
assert_contains "state body updated"      "working on smoke test" "$STATE_CONTENT"
assert_contains "state has type cpm-state" "type: cpm-state" "$STATE_CONTENT"

printf '\n=== store (stdin content) ===\n'

STDIN_ID="$(printf 'stdin content body' | "$CLI" store --kind note --slot smoke)"
STDIN_FILE="$VAULT/smoke/notes/$(echo "$STDIN_ID" | awk -F/ '{print $3}').md"
STDIN_CONTENT="$(cat "$STDIN_FILE")"
assert_contains "stdin content stored" "stdin content body" "$STDIN_CONTENT"

printf '\n=== store (archive) ===\n'

ARCH_ID="$("$CLI" store "archived conversation" --kind archive --slot smoke)"
assert_contains "archive id minted" "smoke/archive/" "$ARCH_ID"
ARCH_REL="$(echo "$ARCH_ID" | awk -F/ '{print $3}')"
ARCH_YYYY="${ARCH_REL:0:4}"
ARCH_MM="${ARCH_REL:4:2}"
assert "archive routed to YYYY/MM dir" test -f "$VAULT/smoke/conversations/$ARCH_YYYY/$ARCH_MM/$ARCH_REL.md"

printf '\n=== list ===\n'

LIST_OUT="$("$CLI" list --slot smoke)"
assert_contains "list includes state"       "smoke/state/state" "$LIST_OUT"
assert_contains "list includes summary"     "smoke/summary/kickoff" "$LIST_OUT"
assert_contains "list includes note"        "smoke/note/" "$LIST_OUT"
assert_contains "list includes archive"     "smoke/archive/" "$LIST_OUT"

# filter
FILTER_OUT="$("$CLI" list --slot smoke --filter summary)"
assert_contains "list --filter summary returns summary id" "smoke/summary/kickoff" "$FILTER_OUT"
case "$FILTER_OUT" in
    *"smoke/note/"*) FAIL=$((FAIL + 1)); printf '  FAIL  list --filter summary should exclude notes\n' >&2 ;;
    *) PASS=$((PASS + 1)); printf '  PASS  list --filter summary excludes notes\n' ;;
esac

printf '\n=== recall ===\n'

RECALL_OUT="$("$CLI" recall "kickoff" --slot smoke)"
assert_contains "recall summary mode finds kickoff" "smoke/summary/kickoff" "$RECALL_OUT"

RECALL_ALL="$("$CLI" recall "kickoff" --slot smoke --scope all-by-topic)"
assert_contains "recall all-by-topic emits body" "kickoff brief summary" "$RECALL_ALL"

# Recall miss prints to stderr and returns 0.
if MISS_OUT="$("$CLI" recall "no_such_string_in_vault_xyz" --slot smoke 2>&1)"; then
    assert_contains "recall miss reports nicely" "no matches for" "$MISS_OUT"
else
    FAIL=$((FAIL + 1))
    printf '  FAIL  recall miss should exit 0 not %s\n' "$?" >&2
fi

printf '\n=== update ===\n'

UPDATED_ID="$("$CLI" update "$NOTE_ID" "updated note body")"
assert "update returns same memory_id" test "$UPDATED_ID" = "$NOTE_ID"
UPDATED_CONTENT="$(cat "$NOTE_FILE")"
assert_contains "update replaced body" "updated note body" "$UPDATED_CONTENT"
case "$UPDATED_CONTENT" in
    *"first note body"*)
        FAIL=$((FAIL + 1))
        printf '  FAIL  update should have removed old body\n' >&2
        ;;
    *)
        PASS=$((PASS + 1))
        printf '  PASS  update removed old body\n'
        ;;
esac

# Update from stdin.
printf 'stdin patched body' | "$CLI" update "$NOTE_ID" >/dev/null
ASSERT_AFTER="$(cat "$NOTE_FILE")"
assert_contains "update from stdin works" "stdin patched body" "$ASSERT_AFTER"

# Malformed memory_id.
if BAD_OUT="$("$CLI" update "garbage" "no" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  update of bogus memory_id should fail\n' >&2
else
    assert_contains "update of bogus memory_id complains" "malformed" "$BAD_OUT"
fi

# Missing file.
if MISSING_OUT="$("$CLI" update "smoke/note/nonexistent" "x" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  update of missing file should fail\n' >&2
else
    assert_contains "update of missing file complains" "does not exist" "$MISSING_OUT"
fi

printf '\n=== invalid args ===\n'

if BAD_KIND="$("$CLI" store "x" --kind bogus --slot smoke 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  store with bogus kind should fail\n' >&2
else
    assert_contains "invalid kind rejected" "invalid --kind" "$BAD_KIND"
fi

if BAD_PRIV="$("$CLI" store "x" --kind note --privacy bogus --slot smoke 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  store with bogus privacy should fail\n' >&2
else
    assert_contains "invalid privacy rejected" "invalid --privacy" "$BAD_PRIV"
fi

if BAD_SUM="$("$CLI" store "x" --kind summary --slot smoke 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  summary without --topic should fail\n' >&2
else
    assert_contains "summary without --topic rejected" "topic" "$BAD_SUM"
fi

printf '\n=== git commit shape ===\n'

# Every Store/Update should have produced a commit.
COMMITS="$(git -C "$WORK" log --oneline | wc -l | tr -d ' ')"
multi_commits() { [ "$COMMITS" -ge 6 ]; }
assert "produced multiple commits ($COMMITS)" multi_commits

# --- Summary. ----------------------------------------------------------------

printf '\n=== summary ===\n'
printf '  pass: %d\n' "$PASS"
printf '  fail: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
