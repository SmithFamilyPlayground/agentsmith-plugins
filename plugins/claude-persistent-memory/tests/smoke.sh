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

# --- Regression suite for Jax cross-vendor findings on PR #12. --------------
# Each block below targets one of the HIGH / MEDIUM findings and asserts
# the fix holds. Keep these even if individual blocks look small — they
# guard against silent regression on the same shapes Jax flagged.

printf '\n=== HIGH-1: path-traversal memory_id rejection ===\n'

# `update <slot>/<kind>/<id>` with traversal bits in any segment must
# fail with a "malformed" / "disallowed" / "must not be" error and
# leave the file system untouched. We don't need to exhaust every
# pattern — a representative `..` segment, a `/` smuggle, and a
# leading-`.` segment cover the surface.

# Plant a sentinel "outside-the-vault" file we want to prove untouched.
SENTINEL="$WORK/SHOULD_NOT_BE_TOUCHED"
printf 'original-content\n' > "$SENTINEL"
SENTINEL_BEFORE="$(cat "$SENTINEL")"

# Case A: classic `..` traversal in id segment (e.g. trying to land
# on a file outside the slot). The defensive validator can fire on
# any of "must not be", "must not start with", or "disallowed" depending
# on which rule the segment trips first — all are acceptable rejections.
if TRAV_A="$("$CLI" update "smoke/note/..%2Ffoo" "evil" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  traversal id (encoded) should fail\n' >&2
else
    case "$TRAV_A" in
        *disallowed*|*"must not be"*|*"must not start with"*|*malformed*)
            PASS=$((PASS + 1)); printf '  PASS  encoded-slash id rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  encoded-slash id error unclear: %s\n' "$TRAV_A" >&2 ;;
    esac
fi

# Case B: extra `/` past the second separator. The naive `read -r slot kind id`
# would put `note/../../SHOULD_NOT_BE_TOUCHED` into `id`; we reject on
# the reassembly mismatch OR the disallowed-chars check.
if TRAV_B="$("$CLI" update "smoke/note/../../SHOULD_NOT_BE_TOUCHED" "evil" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  multi-segment traversal should fail\n' >&2
else
    case "$TRAV_B" in
        *malformed*|*disallowed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  multi-segment traversal rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  traversal error message unclear: %s\n' "$TRAV_B" >&2 ;;
    esac
fi

# Case C: leading-dot slot via the `update` parser (`.hidden/...`).
if TRAV_C="$("$CLI" update ".hidden/note/abc" "evil" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  leading-dot slot should fail\n' >&2
else
    assert_contains "leading-dot slot rejected" "must not start with" "$TRAV_C"
fi

# Case D: `--slot ..` for `list`/`recall`/`store` must also fail.
if TRAV_D="$("$CLI" list --slot .. 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  list --slot .. should fail\n' >&2
else
    assert_contains "list --slot .. rejected" "must not be" "$TRAV_D"
fi

# Case E: `--identity ..` for `init` must fail before any directory is
# created. Use a throwaway sub-path so we can verify nothing landed.
TRAV_INIT_DIR="$WORK/trav-init-target"
if TRAV_E="$("$CLI" init --path "$TRAV_INIT_DIR" --identity .. 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  init --identity .. should fail\n' >&2
else
    assert_contains "init --identity .. rejected" "must not be" "$TRAV_E"
fi

# Sentinel must be byte-identical to before any of the traversal attempts.
SENTINEL_AFTER="$(cat "$SENTINEL")"
if [ "$SENTINEL_BEFORE" = "$SENTINEL_AFTER" ]; then
    PASS=$((PASS + 1)); printf '  PASS  sentinel file outside vault untouched\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  sentinel file was clobbered by traversal\n' >&2
fi

printf '\n=== HIGH-1b: multiline-value bypass (second-pass Jax finding) ===\n'

# The first-pass fix validated each id segment with a line-oriented
# `grep -qE '^...$'`. That's bypassed by a multi-line value: grep matches
# per line, so `"clean\n../../outside"` PASSES because line 1 ("clean")
# matches the regex. LLM output routinely carries stray newlines, making
# this a realistic surface — not a theoretical one.
#
# Fix is bash regex `[[ =~ ]]` which matches whole-string. These assertions
# cover the four caller surfaces that feed user input into the validator:
# init --identity, store --slot, list --slot, and update <memory_id> (where
# the newline rides in on one of the three segments after IFS='/' read).

MULTILINE_SENTINEL="$WORK/MULTILINE_SHOULD_NOT_BE_TOUCHED"
printf 'multiline-original\n' > "$MULTILINE_SENTINEL"
MULTILINE_BEFORE="$(cat "$MULTILINE_SENTINEL")"

# Case A: init --identity with embedded newline + traversal payload.
ML_INIT_TARGET="$WORK/multiline-init-target"
ml_identity=$'clean\n../../MULTILINE_SHOULD_NOT_BE_TOUCHED'
if ML_A="$("$CLI" init --path "$ML_INIT_TARGET" --identity "$ml_identity" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  init --identity with embedded newline should fail\n' >&2
else
    case "$ML_A" in
        *newline*|*disallowed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  init --identity multiline rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  init multiline error unclear: %s\n' "$ML_A" >&2 ;;
    esac
fi
# init must not have created any directories under the throwaway target.
# (Validator runs before any mkdir, so the target shouldn't exist at all;
# but accept either "doesn't exist" or "exists and is empty" as proof
# the validator fired before disk side-effects.)
ml_init_leak=""
if [ -d "$ML_INIT_TARGET" ]; then
    ml_init_leak="$(find "$ML_INIT_TARGET" -mindepth 1 -maxdepth 3 2>/dev/null | head -1)"
fi
if [ -z "$ml_init_leak" ]; then
    PASS=$((PASS + 1)); printf '  PASS  init multiline left no disk artefacts\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  init multiline created disk artefact: %s\n' "$ml_init_leak" >&2
fi

# Case B: store --slot with embedded newline. Note: --slot is consumed
# by cpm_store_cmd then passed to cpm_store which calls the validator
# BEFORE the slot-directory existence check, so the error must come
# from the validator (not from "slot does not exist").
ml_slot=$'smoke\n../../MULTILINE_SHOULD_NOT_BE_TOUCHED'
if ML_B="$("$CLI" store "body" --kind note --slot "$ml_slot" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  store --slot multiline should fail\n' >&2
else
    case "$ML_B" in
        *newline*|*disallowed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  store --slot multiline rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  store --slot multiline error unclear: %s\n' "$ML_B" >&2 ;;
    esac
fi

# Case C: list --slot with embedded newline.
if ML_C="$("$CLI" list --slot "$ml_slot" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  list --slot multiline should fail\n' >&2
else
    case "$ML_C" in
        *newline*|*disallowed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  list --slot multiline rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  list --slot multiline error unclear: %s\n' "$ML_C" >&2 ;;
    esac
fi

# Case C2: recall --slot with embedded newline. Same validator chain
# as list (cpm_recall calls _cpm_validate_id_segment before any disk
# walk), but the dispatch path is different so worth its own assertion.
if ML_C2="$("$CLI" recall "kickoff" --slot "$ml_slot" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  recall --slot multiline should fail\n' >&2
else
    case "$ML_C2" in
        *newline*|*disallowed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  recall --slot multiline rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  recall --slot multiline error unclear: %s\n' "$ML_C2" >&2 ;;
    esac
fi

# Case D: update <memory_id> with embedded newline in the id segment.
# `IFS='/' read -r slot kind id` puts everything-after-the-second-/ into
# `id`, so a newline embedded in the id (third segment) survives the
# read and is then handed to _cpm_validate_id_segment.
ml_memory_id=$'smoke/note/clean\n../../MULTILINE_SHOULD_NOT_BE_TOUCHED'
if ML_D="$("$CLI" update "$ml_memory_id" "evil" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  update memory_id with embedded newline should fail\n' >&2
else
    case "$ML_D" in
        *newline*|*disallowed*|*malformed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  update memory_id multiline rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  update memory_id multiline error unclear: %s\n' "$ML_D" >&2 ;;
    esac
fi

# Case E: multiline newline in the SLOT segment of a memory_id (first
# field after IFS=/ read). Confirms whole-id splitting also catches
# newlines on the early segments. Use a leading slot with a newline +
# traversal payload, then a benign kind/id.
ml_memory_id_slot=$'clean\n../../MULTILINE_SHOULD_NOT_BE_TOUCHED/note/abc'
if ML_E="$("$CLI" update "$ml_memory_id_slot" "evil" 2>&1)"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  update slot-segment newline should fail\n' >&2
else
    case "$ML_E" in
        *newline*|*disallowed*|*malformed*|*"must not"*)
            PASS=$((PASS + 1)); printf '  PASS  update slot-segment newline rejected\n' ;;
        *)
            FAIL=$((FAIL + 1)); printf '  FAIL  update slot-segment newline error unclear: %s\n' "$ML_E" >&2 ;;
    esac
fi

# Sentinel must be byte-identical to before any of the multiline attempts.
# (Content comparison is the authoritative safety property: any clobber
# changes content, so this single check covers both "still exists" and
# "still original bytes".)
MULTILINE_AFTER="$(cat "$MULTILINE_SENTINEL")"
if [ "$MULTILINE_BEFORE" = "$MULTILINE_AFTER" ]; then
    PASS=$((PASS + 1)); printf '  PASS  multiline sentinel file untouched\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  multiline sentinel file was clobbered\n' >&2
fi

printf '\n=== HIGH-2: git commit pathspec-scoped ===\n'

# Operator pre-stages an unrelated file. cpm Store/Update must commit
# ONLY its own paths, leaving the pre-staged file in the index for the
# operator's next commit. We assert (a) the cpm commit subject does not
# also contain the unrelated path, and (b) the unrelated file is still
# in the index after the cpm commit.

UNRELATED="$WORK/unrelated-operator-work.txt"
printf 'operator was mid-edit\n' > "$UNRELATED"
git -C "$WORK" add -- "$UNRELATED"

# Pre-condition: unrelated IS staged.
git -C "$WORK" diff --cached --quiet -- "$UNRELATED" && {
    FAIL=$((FAIL + 1)); printf '  FAIL  pre-condition: unrelated file not staged\n' >&2
}

PATHSPEC_NOTE_ID="$("$CLI" store "pathspec test body" --kind note --slot smoke)"
COMMIT_FILES="$(git -C "$WORK" show --name-only --format= HEAD)"

# (a) cpm commit should not have included the unrelated file.
case "$COMMIT_FILES" in
    *"unrelated-operator-work.txt"*)
        FAIL=$((FAIL + 1)); printf '  FAIL  cpm commit swept unrelated pre-staged file\n' >&2 ;;
    *)
        PASS=$((PASS + 1)); printf '  PASS  cpm commit excluded pre-staged unrelated file\n' ;;
esac

# (b) Unrelated file should still be staged.
if git -C "$WORK" diff --cached --quiet -- "$UNRELATED"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  pre-staged file lost from index after cpm commit\n' >&2
else
    PASS=$((PASS + 1)); printf '  PASS  pre-staged file remains in index after cpm commit\n'
fi

# Cleanup so subsequent assertions start from a clean index.
git -C "$WORK" reset --quiet HEAD -- "$UNRELATED" 2>/dev/null || true
rm -f "$UNRELATED"

# Quiet shellcheck on the unused id capture (kept for diagnostic clarity).
: "$PATHSPEC_NOTE_ID"

printf '\n=== HIGH-3: awk update preserves literal backslashes ===\n'

# Patch containing literal backslashes (\n, \t, \\, JSON-escape forms,
# Windows path). The bytes on disk must match the input exactly — no
# silent \n → LF rewriting.
BACKSLASH_BODY='line1\nline2 keep_literal_\t and \\ double and "json\"quote" and C:\Users\path'
ESCAPE_TARGET_ID="$NOTE_ID"
printf '%s' "$BACKSLASH_BODY" | "$CLI" update "$ESCAPE_TARGET_ID" >/dev/null
ESCAPE_TARGET_FILE="$NOTE_FILE"

# Body lives between the closing `---` and EOF; awk-extract it once
# and compare bytewise.
ESCAPE_AFTER="$(awk '
    BEGIN { in_fm = 0; started = 0; past = 0 }
    /^---[[:space:]]*$/ {
        if (!started) { in_fm = 1; started = 1; next }
        if (in_fm) { in_fm = 0; past = 1; next }
    }
    past { print }
' "$ESCAPE_TARGET_FILE")"

# Body has a trailing newline from cpm_store/update's printf; the
# stored body should still contain our literal backslashes.
case "$ESCAPE_AFTER" in
    *'\n'*) PASS=$((PASS + 1)); printf '  PASS  literal \\n preserved\n' ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  literal \\n lost (got: %s)\n' "$ESCAPE_AFTER" >&2 ;;
esac
case "$ESCAPE_AFTER" in
    *'\t'*) PASS=$((PASS + 1)); printf '  PASS  literal \\t preserved\n' ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  literal \\t lost\n' >&2 ;;
esac
# shellcheck disable=SC1003
# We literally want to glob for two backslashes in a row, not escape
# a quote. SC1003 misfires on single-quoted glob patterns.
case "$ESCAPE_AFTER" in
    *'\\'*) PASS=$((PASS + 1)); printf '  PASS  literal \\\\ preserved\n' ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  literal \\\\ collapsed\n' >&2 ;;
esac
case "$ESCAPE_AFTER" in
    *'C:\Users\path'*) PASS=$((PASS + 1)); printf '  PASS  Windows path preserved\n' ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  Windows path mangled\n' >&2 ;;
esac

printf '\n=== MEDIUM: frontmatter preserved on state/summary re-store ===\n'

# (1) state re-store without --privacy must NOT reset privacy.
# Tighten privacy via an explicit Memory.Store call.
printf 'private state body' | "$CLI" store - --kind state --slot smoke --privacy private >/dev/null
STATE_PATH="$VAULT/smoke/state.md"
STATE_PRIV_BEFORE="$(grep '^privacy:' "$STATE_PATH" | head -1 | awk '{print $2}')"
assert "privacy: private set on state re-store" test "$STATE_PRIV_BEFORE" = "private"

# Now re-store WITHOUT --privacy — must preserve `private`, not reset
# to `family-internal`.
printf 'updated state body, no privacy passed' | "$CLI" store - --kind state --slot smoke >/dev/null
STATE_PRIV_AFTER="$(grep '^privacy:' "$STATE_PATH" | head -1 | awk '{print $2}')"
if [ "$STATE_PRIV_AFTER" = "private" ]; then
    PASS=$((PASS + 1)); printf '  PASS  state re-store preserved privacy=private\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  state re-store reset privacy to %s\n' "$STATE_PRIV_AFTER" >&2
fi

# (2) summary re-store: same rule. First set privacy: private.
"$CLI" store "fm-preserve summary v1" --kind summary --topic fm-preserve --slot smoke --privacy private >/dev/null
FM_PATH="$VAULT/smoke/topics/fm-preserve.md"
FM_PRIV_BEFORE="$(grep '^privacy:' "$FM_PATH" | head -1 | awk '{print $2}')"
assert "summary first-store with --privacy private" test "$FM_PRIV_BEFORE" = "private"

# Re-store without --privacy. Must keep private.
"$CLI" store "fm-preserve summary v2" --kind summary --topic fm-preserve --slot smoke >/dev/null
FM_PRIV_AFTER="$(grep '^privacy:' "$FM_PATH" | head -1 | awk '{print $2}')"
if [ "$FM_PRIV_AFTER" = "private" ]; then
    PASS=$((PASS + 1)); printf '  PASS  summary re-store preserved privacy=private\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  summary re-store reset privacy to %s\n' "$FM_PRIV_AFTER" >&2
fi

# (3) Explicit --privacy on re-store DOES override existing.
"$CLI" store "fm-preserve summary v3" --kind summary --topic fm-preserve --slot smoke --privacy public >/dev/null
FM_PRIV_OVERRIDE="$(grep '^privacy:' "$FM_PATH" | head -1 | awk '{print $2}')"
if [ "$FM_PRIV_OVERRIDE" = "public" ]; then
    PASS=$((PASS + 1)); printf '  PASS  explicit --privacy on re-store overrides existing\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  explicit --privacy override failed (got %s)\n' "$FM_PRIV_OVERRIDE" >&2
fi

# (4) first-store with no --privacy still defaults to family-internal.
"$CLI" store "first-store-no-privacy body" --kind summary --topic first-store-default --slot smoke >/dev/null
FSD_PATH="$VAULT/smoke/topics/first-store-default.md"
FSD_PRIV="$(grep '^privacy:' "$FSD_PATH" | head -1 | awk '{print $2}')"
if [ "$FSD_PRIV" = "family-internal" ]; then
    PASS=$((PASS + 1)); printf '  PASS  first-store default privacy=family-internal\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  first-store default privacy not family-internal (got %s)\n' "$FSD_PRIV" >&2
fi

printf '\n=== LOW: archive YYYY/MM derived from id (no TOCTOU) ===\n'

# An archive store mints id `<YYYYMMDDTHHMMSSZ>-<rand>` and routes the
# file to <slot>/conversations/<YYYY>/<MM>/. The fix derives YYYY/MM
# from the id itself rather than re-reading `date`, so the on-disk
# path must always agree with the id even if minute/hour/month bounds
# tick between the calls. We can't easily race a real boundary in CI,
# but we can prove the invariant: substring(id, 0, 4) and
# substring(id, 4, 2) match the directory the file landed in.

TOCTOU_ID="$("$CLI" store "toctou archive body" --kind archive --slot smoke)"
TOCTOU_REL="$(echo "$TOCTOU_ID" | awk -F/ '{print $3}')"
TOCTOU_YYYY="${TOCTOU_REL:0:4}"
TOCTOU_MM="${TOCTOU_REL:4:2}"
TOCTOU_PATH="$VAULT/smoke/conversations/$TOCTOU_YYYY/$TOCTOU_MM/$TOCTOU_REL.md"
if [ -f "$TOCTOU_PATH" ]; then
    PASS=$((PASS + 1)); printf '  PASS  archive landed in YYYY/MM derived from id\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  archive id %s not at %s\n' "$TOCTOU_ID" "$TOCTOU_PATH" >&2
fi

# And `update` (which uses the same id-recovery slicing) must be able
# to find the file by round-tripping the id.
printf 'toctou updated body' | "$CLI" update "$TOCTOU_ID" >/dev/null
TOCTOU_AFTER="$(cat "$TOCTOU_PATH")"
assert_contains "update of archive by id round-trips" "toctou updated body" "$TOCTOU_AFTER"

printf '\n=== LOW: update temp file written next to target; no leak on success ===\n'

# After a successful update, no `.cpm-update.*` temp file should remain
# in the target file's directory. (Pre-fix, mktemp wrote to /tmp and
# was always cleaned by the trap; the fix moves the tmp adjacent to
# the target so the rename is same-filesystem atomic — leftover temp
# files in the same dir would mean the trap or rename is broken.)

UPDATE_TARGET_DIR="$(dirname "$NOTE_FILE")"
printf 'tmp-locality check body' | "$CLI" update "$NOTE_ID" >/dev/null
LEFTOVER_COUNT="$(find "$UPDATE_TARGET_DIR" -maxdepth 1 -name '.cpm-update.*' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEFTOVER_COUNT" = "0" ]; then
    PASS=$((PASS + 1)); printf '  PASS  no .cpm-update.* temp file left after update\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s .cpm-update.* leftover temp file(s) in %s\n' "$LEFTOVER_COUNT" "$UPDATE_TARGET_DIR" >&2
fi

# Also confirm that the post-fix update still leaves /tmp unaffected
# by .cpm-update.* files from THIS run. (Defensive; pre-fix the temp
# WOULD land in /tmp.) Scope to /tmp/.cpm-update.* glob just for this
# test run.
TMP_LEFTOVER="$(find /tmp -maxdepth 1 -name '.cpm-update.*' -newer "$WORK" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$TMP_LEFTOVER" = "0" ]; then
    PASS=$((PASS + 1)); printf '  PASS  update did not stage temp file in /tmp\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  update staged %s temp file(s) in /tmp\n' "$TMP_LEFTOVER" >&2
fi

# --- Summary. ----------------------------------------------------------------

printf '\n=== summary ===\n'
printf '  pass: %d\n' "$PASS"
printf '  fail: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
