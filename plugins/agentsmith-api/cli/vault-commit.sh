#!/usr/bin/env bash
# vault-commit.sh — stage, commit, and push vault changes to the
# long-lived `today` branch. Intended for agents to call instead of
# using raw git.
#
# This is the agentsmith-api bundled copy. The AgentSmith repo's
# `shared/scripts/vault-commit.sh` is the lineage source; this copy
# adds two flags (--scan-mode, --mode) per api spec §V.1.
# Decommission of the AgentSmith-repo copy is a Phase 3 concern (out
# of scope for this PR).
#
# Behavior:
#   1. cd into the vault (~/.secondbrain).
#   2. Ensure we're on `today`. If not, fetch, create from
#      origin/today if the branch does not yet exist locally, or
#      check out the existing one and fast-forward to origin.
#   3. Stage tracked + untracked changes, skipping anything under the
#      vault's raw/ directories (agents must not modify raw/).
#   4. Set the committer to the agent's bot identity based on
#      $TOD_AGENT_NAME (or the --agent flag).
#   5. Commit with the provided message, appending the agent name.
#   6. Push `today`.
#
# Rollup happens out-of-band via the SecondBrain `daily-rollup.yml`
# GHA workflow, which snapshots `today` HEAD as a `daily-YYYY-MM-DD`
# branch + tag and opens a PR to main. See AgentSmith spec
# `docs/superpowers/specs/2026-05-08-secondbrain-today-branch.md`
# for the full design and `shared/runbooks/today-branch-cutover.md`
# for the deploy-order constraint.
#
# Usage:
#   vault-commit.sh "short message"
#   vault-commit.sh --agent jef "jef researched X, Y, Z"
#   vault-commit.sh --dry-run "message"             # show what would be committed
#   vault-commit.sh --scan-mode skip "message"      # skip §V.4 Haiku scan (default)
#   vault-commit.sh --scan-mode full "message"      # phase-2b — warns + proceeds in phase-2a
#   vault-commit.sh --mode local "message"          # skip today-branch ops (test/dev mode)
#
# Env:
#   TOD_AGENT_NAME   default agent if --agent is not given
#   VAULT_PATH       default: ~/.secondbrain
#
# Exit codes:
#   0 = committed + pushed (or nothing to commit)
#   2 = illegal state (raw/ modification, missing origin/today,
#       unknown agent, dirty workdir that cannot be stashed, etc.)
#   other = git/push error

set -euo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/.secondbrain}"
AGENT="${TOD_AGENT_NAME:-}"
DRY_RUN="no"
SCAN_MODE="skip"
MODE="today"
MSG=""

log()  { printf '\033[0;34m[vault-commit]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[vault-commit]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[vault-commit]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[vault-commit]\033[0m %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      [[ $# -ge 2 ]] || die "missing value for --agent"
      AGENT="${2:-}"
      [[ -n "${AGENT}" ]] || die "missing value for --agent"
      # Reject values that look like another flag — `--agent --dry-run msg`
      # would otherwise consume `--dry-run` as the agent name and fail
      # later at the allowlist check with a less-actionable error.
      [[ "${AGENT}" != -* ]] || die "missing value for --agent (got flag '${AGENT}')"
      shift 2 ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    --scan-mode)
      [[ $# -ge 2 ]] || die "missing value for --scan-mode"
      SCAN_MODE="${2:-}"
      [[ "${SCAN_MODE}" != -* ]] || die "missing value for --scan-mode (got flag '${SCAN_MODE}')"
      case "${SCAN_MODE}" in
        full|skip) ;;
        *) die "invalid --scan-mode '${SCAN_MODE}' (full|skip)" ;;
      esac
      shift 2 ;;
    --mode)
      [[ $# -ge 2 ]] || die "missing value for --mode"
      MODE="${2:-}"
      [[ "${MODE}" != -* ]] || die "missing value for --mode (got flag '${MODE}')"
      case "${MODE}" in
        today|local) ;;
        *) die "invalid --mode '${MODE}' (today|local)" ;;
      esac
      shift 2 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown flag: $1" ;;
    *) MSG="${MSG:+$MSG }$1"; shift ;;
  esac
done

[[ -n "${MSG}" ]] || die "commit message required"
[[ -n "${AGENT}" ]] || die "agent name required (set TOD_AGENT_NAME or pass --agent)"
case "${AGENT}" in
  tod|amy|sam|ema|jon|jef|jax|agentsmith) ;;
  *) die "unknown agent '${AGENT}' (expected: tod, amy, sam, ema, jon, jef, jax, agentsmith)" ;;
esac
[[ -d "${VAULT_PATH}/.git" ]] || die "vault not a git repo at ${VAULT_PATH}"

# Haiku scan (api spec §V.4). Phase-2a stubs this: --scan-mode full
# warns "not yet implemented" and proceeds; skip is a no-op.
if [[ "${SCAN_MODE}" == "full" ]]; then
  warn "Haiku PII/secrets scan (--scan-mode full) not yet implemented in phase-2a — treating as skip; the regex-layer block-secret-writes hook is the only secret-defence today"
fi

cd "${VAULT_PATH}"

# --mode local short-circuit: pathspec-scoped commit on the current
# branch, no today-branch hop, no push. For tests + non-AgentSmith
# vault layouts; api spec §V.1 selector for the standalone passthrough.
if [[ "${MODE}" == "local" ]]; then
  NAME="${AGENT}-bot"
  EMAIL="${AGENT}-bot@smith.family"
  git add -A
  if git diff --cached --quiet; then
    ok "no changes to commit (mode=local)"
    exit 0
  fi
  if [[ "${DRY_RUN}" == "yes" ]]; then
    log "DRY RUN — would commit on current branch as ${NAME} <${EMAIL}> (mode=local)"
    git diff --cached --stat
    exit 0
  fi
  GIT_AUTHOR_NAME="${NAME}" GIT_AUTHOR_EMAIL="${EMAIL}" \
  GIT_COMMITTER_NAME="${NAME}" GIT_COMMITTER_EMAIL="${EMAIL}" \
    git commit --quiet -m "${MSG}

Committed by ${AGENT} via vault-commit.sh (mode=local) on $(date -u +%FT%TZ)."
  ok "committed (mode=local; no push)"
  exit 0
fi

# Fetch the remote's main + today branch, quietly.
git fetch origin --prune --quiet

BRANCH="today"

current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"

# Stash any pending workdir state before the branch hop. Stale
# branches (e.g., legacy daily/YYYY-MM-DD from before the today-branch
# cutover) plus a workdir mod to a file that doesn't exist on
# origin/today would otherwise block the checkout.
#
# We use `git stash push -u` (NOT `git stash create -u`) for two
# reasons:
#   1. `git stash create -u` does NOT actually capture untracked
#      files in git 2.39 — it accepts the flag but produces a
#      2-parent merge commit with no untracked-tree parent, so a
#      subsequent `git clean -fdq` would silently destroy any
#      untracked file in the workdir. `push -u` produces the
#      correct 3-parent commit.
#   2. `push -u` also clears the workdir as a side effect, so we
#      don't need a follow-up `reset --hard` + `clean -fdq` (the
#      previous shape of this code, which was the data-loss path).
#
# We then capture the stash commit SHA via `git rev-parse stash@{0}`
# IMMEDIATELY after the push (before any other stash op can race
# with us). The SHA is invariant — apply/drop by SHA never touches
# a pre-existing user stash entry, even if the stack is reordered.
STASHED="no"
STASH_SHA=""
STASH_TAG="vault-commit cross-branch-hop $(date -u +%FT%T%NZ)"
if [[ "${current_branch}" != "${BRANCH}" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    log "stashing workdir before switching to ${BRANCH}"
    if git stash push -u --quiet --message "${STASH_TAG}"; then
      STASH_SHA="$(git rev-parse --verify --quiet 'stash@{0}' || true)"
      if [[ -n "${STASH_SHA}" ]]; then
        STASHED="yes"
      else
        die "git stash push succeeded but stash@{0} not resolvable; refusing to checkout ${BRANCH} with dirty workdir"
      fi
    else
      die "git stash push -u failed with dirty porcelain; refusing to checkout ${BRANCH} and risk carrying changes across branches"
    fi
  fi
fi

# Create or switch to the `today` branch. Unlike the legacy
# daily/YYYY-MM-DD shape, `today` is a single long-lived branch —
# it must already exist at origin (bootstrapped during the
# today-branch flow cutover). If it doesn't, refuse rather than
# silently create a divergent branch.
#
# The origin/today preflight runs UNCONDITIONALLY — before we
# inspect the local branch. Otherwise a developer or misconfigured
# host with a local `today` (created by hand or left over from a
# divergent state) would silently bootstrap origin/today from a
# wrong base on first push via --set-upstream, contradicting the
# header contract above and the runbook's "missing origin/today"
# guidance.
if ! git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
  die "origin/${BRANCH} does not exist; today-branch bootstrap must run first (see SecondBrain repo + spec 2026-05-08-secondbrain-today-branch.md)"
fi

if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "${BRANCH}" --quiet
  # Fast-forward to origin if it has moved. origin/${BRANCH} is
  # guaranteed to exist by the preflight above.
  git merge --ff-only "origin/${BRANCH}" --quiet \
    || die "local ${BRANCH} diverged from remote; fix manually"
else
  git checkout -b "${BRANCH}" "origin/${BRANCH}" --quiet
fi

# Restore the stash if we made one. We apply by SHA (captured above)
# rather than by `stash@{0}`, so any pre-existing user stash entries
# stay safely off to the side.
#
# Conflict handling: resolve modify-delete (UD/AU/DU/UA) by keeping
# the stashed (user's pending) version, but never under a raw/ path.
# Treat anything else (rename/copy/type-change/real merge conflicts)
# as fatal — abort and ask the operator to resolve manually rather
# than silently swallow.
if [[ "${STASHED}" == "yes" && -n "${STASH_SHA}" ]]; then
  if git stash apply --quiet "${STASH_SHA}"; then
    :  # clean apply
  else
    apply_rc=$?
    # Inspect porcelain v1 with -z (NUL-separated, no quoting). Each
    # entry is "XY<space><path>" where XY is the two-letter status
    # code; rename/copy entries have an additional NUL-separated
    # original-path field that we read and discard.
    aborted=0
    saw_conflict=0
    while IFS= read -r -d '' entry; do
      code="${entry:0:2}"
      path="${entry:3}"
      # Renames/copies emit an extra NUL-separated original path —
      # consume and discard it so the next iteration is aligned.
      case "${code}" in
        R?|?R|C?|?C) IFS= read -r -d '' _orig || true ;;
      esac
      case "${code}" in
        "UD"|"AU"|"DU"|"UA")
          saw_conflict=1
          if [[ "${path}" =~ (^|/)raw/ ]]; then
            warn "modify-delete conflict under raw/ — refusing to override (path: ${path})"
            aborted=1
          else
            log "resolving modify-delete on ${path} by keeping stashed version"
            git add -- "${path}" || aborted=1
          fi
          ;;
        "UU"|"AA"|"DD")
          saw_conflict=1
          warn "real merge conflict on ${path} (status ${code}); aborting"
          aborted=1
          ;;
        R?|?R|C?|?C|T?|?T)
          # Rename / copy / type-change conflicts are out of scope for
          # auto-resolution — bail rather than guess.
          warn "unsupported conflict shape on ${path} (status ${code}); aborting"
          saw_conflict=1
          aborted=1
          ;;
      esac
    done < <(git status -z --porcelain)
    if (( aborted )); then
      die "stash-apply conflicts could not be auto-resolved; stash preserved at ${STASH_SHA} — resolve manually"
    fi
    if (( saw_conflict == 0 )); then
      # apply rc != 0 with no conflict markers — surface the real error.
      die "git stash apply failed (rc=${apply_rc}) without producing conflicts; stash preserved at ${STASH_SHA}"
    fi
  fi
  # Drop the stored stash entry now that it's been integrated.
  # Resolve by SHA (not by message-tag) — the tag has at-most
  # nanosecond precision but a colliding pre-existing user stash
  # message could still match. Look up the index whose commit SHA
  # equals our captured STASH_SHA and drop that index explicitly.
  stash_ref="$(git stash list --format='%gd %H' \
                 | awk -v sha="${STASH_SHA}" '$2 == sha {print $1; exit}')"
  if [[ -n "${stash_ref}" ]]; then
    git stash drop --quiet "${stash_ref}" || warn "stash drop failed for ${stash_ref}"
  else
    warn "could not locate stash entry for SHA ${STASH_SHA} to drop; left in place"
  fi
fi

# Safety: refuse if anything under an owned raw/ dir is modified.
# Use --porcelain -z and parse NUL-separated entries so paths with
# spaces, quotes, backslashes, or newlines can't slip past the check.
#
# For renames/copies (R?/?R/C?/?C) the old path is also relevant —
# `git mv raw/foo outside/bar` is a raw/-immutability violation
# even though the new path is outside raw/. Inspect both old and
# new paths against the regex.
raw_hits=()
while IFS= read -r -d '' entry; do
  code="${entry:0:2}"
  path="${entry:3}"
  orig=""
  case "${code}" in
    R?|?R|C?|?C) IFS= read -r -d '' orig || true ;;
  esac
  if [[ "${path}" =~ (^|/)raw/ ]]; then
    raw_hits+=("${entry}")
  elif [[ -n "${orig}" && "${orig}" =~ (^|/)raw/ ]]; then
    raw_hits+=("${entry} (renamed/copied from ${orig})")
  fi
done < <(git status -z --porcelain)
if (( ${#raw_hits[@]} > 0 )); then
  printf '%s\n' "${raw_hits[@]}" >&2
  die "raw/ directory contents are immutable — remove these changes before committing"
fi

# Stage everything (respects .gitignore).
git add -A

# Nothing to commit?
if git diff --cached --quiet; then
  ok "no changes to commit on ${BRANCH}"
  exit 0
fi

# Agent identity.
NAME="${AGENT}-bot"
EMAIL="${AGENT}-bot@smith.family"

if [[ "${DRY_RUN}" == "yes" ]]; then
  log "DRY RUN — would commit on ${BRANCH} as ${NAME} <${EMAIL}>"
  git diff --cached --stat
  exit 0
fi

GIT_AUTHOR_NAME="${NAME}" GIT_AUTHOR_EMAIL="${EMAIL}" \
GIT_COMMITTER_NAME="${NAME}" GIT_COMMITTER_EMAIL="${EMAIL}" \
  git commit --quiet -m "${MSG}

Committed by ${AGENT} via vault-commit.sh on $(date -u +%FT%TZ)."

log "pushing ${BRANCH}"
# `today` is long-lived and shared across writers (Tod, Jef,
# archive-session hooks). Use --set-upstream — idempotent after
# the first run, and avoids a dead-code branch on the upstream
# config. On non-fast-forward (another writer pushed in between
# our fetch and our push), one retry: fetch, fast-forward the
# local branch, replay our commit on top, push again. If the
# retry also fails, surface the error instead of looping (calling
# context can re-run cleanly).
if ! git push --quiet --set-upstream origin "${BRANCH}"; then
  warn "push rejected (likely concurrent writer); retrying after fetch"
  git fetch origin --quiet
  # Our last commit is HEAD; we want to replay it on top of the
  # refreshed origin/today and push again. Three things to handle:
  #   (a) Anchor the commit SHA in a rescue ref BEFORE any
  #       destructive op, so an operator can recover even if every
  #       subsequent step fails (reflog GC won't claim the SHA).
  #   (b) "Push succeeded but client errored" — first push could
  #       have landed server-side (network blip, slow ACK). After
  #       fetch, if our SHA is already an ancestor of origin/today,
  #       exit 0 idempotently — no replay needed.
  #   (c) Cherry-pick conflict — if the patch can't replay cleanly,
  #       restore HEAD to its pre-reset state and surface the
  #       rescue-ref name so the operator has a clear recovery
  #       handle (rather than just a reflog SHA the calling hook
  #       may have dropped on stderr).
  retry_sha="$(git rev-parse HEAD)"
  rescue_ref="refs/vault-commit-retry/$(date -u +%FT%H%M%SZ)-${retry_sha:0:12}"
  # Fail-fast on update-ref failure. Subsequent die messages reference
  # ${rescue_ref} as a recovery handle; if the anchor doesn't exist
  # because update-ref itself failed (filesystem error, ref-store
  # corruption, etc.), those messages would be misleading and the
  # rescue contract is undermined. Abort BEFORE any destructive op
  # (`git reset --hard`, `git cherry-pick`) so HEAD still points at
  # ${retry_sha} and the operator can recover via reflog.
  git update-ref "${rescue_ref}" "${retry_sha}" \
    || die "could not anchor rescue ref ${rescue_ref}; aborting before destructive ops (commit at HEAD/${retry_sha} — recover via reflog)"

  # (b) Idempotent rerun — first push may have landed.
  if git merge-base --is-ancestor "${retry_sha}" "origin/${BRANCH}"; then
    git update-ref -d "${rescue_ref}" 2>/dev/null || true
    git reset --hard "origin/${BRANCH}" --quiet || true
    ok "committed + pushed ${BRANCH} (retry redundant — origin already has commit ${retry_sha})"
    exit 0
  fi

  if ! git reset --hard "origin/${BRANCH}" --quiet; then
    die "could not reset ${BRANCH} to origin/${BRANCH}; commit preserved at ${rescue_ref} (sha ${retry_sha}) — recover with: git cherry-pick ${rescue_ref}"
  fi
  if ! git cherry-pick --allow-empty --keep-redundant-commits "${retry_sha}" --quiet; then
    git cherry-pick --abort 2>/dev/null || true
    # Restore HEAD to the pre-reset state so the operator sees the
    # work in their reflog AND in the rescue ref.
    git reset --hard "${retry_sha}" --quiet 2>/dev/null || true
    die "cherry-pick of ${retry_sha} onto refreshed origin/${BRANCH} produced conflicts; commit preserved at ${rescue_ref} — recover with: git cherry-pick ${rescue_ref}"
  fi
  if ! git push --quiet --set-upstream origin "${BRANCH}"; then
    die "push to origin/${BRANCH} failed twice (after retry); commit replayed locally and preserved at ${rescue_ref} — recover with: git cherry-pick ${rescue_ref}"
  fi
  # Successful retry — clean up the rescue ref; HEAD is on the
  # replayed commit and the operator no longer needs the anchor.
  git update-ref -d "${rescue_ref}" 2>/dev/null || true
  ok "committed + pushed ${BRANCH} (after retry)"
  exit 0
fi
ok "committed + pushed ${BRANCH}"
