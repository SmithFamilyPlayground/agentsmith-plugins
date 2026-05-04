---
name: self-deploy
description: Use when Tod is about to ship workspace changes to the `tod-smith` fly app via the `main → prod` auto-merge PR. Walks the pre-flight checklist (target detection, WIP push, all-agents-idle gate via `agentsmith-svc /state`, breadcrumb to `state.md`), opens the PR, and on respawn surfaces the deployed SHA from the runtime sidecar. The deploy SIGTERMs Tod — anything not committed before the merge is lost. Never invoke `flyctl deploy` directly; always go through the PR. Triggered by user asks like "deploy", "ship it", "merge to prod" — or when Tod proposes a deploy as the next step in a thread.
---

# self-deploy

The deploy mechanism is a `main → prod` GitHub PR with auto-merge.
Merge to `prod` triggers `.github/workflows/deploy-prod.yml` which
runs `flyctl deploy --remote-only`. Fly replaces Tod's container.
Tod's session ends mid-turn — that's expected.

This skill is the **operator-side ritual around the deploy**: pre-
flight safety checks, breadcrumb, the merge command, and the
post-respawn hello format. It does NOT run `flyctl deploy` itself.
Spec: `docs/superpowers/specs/2026-05-04-self-deploy-design.md`.

## When NOT to use

- **Anything other than `tod-smith`.** This skill is the AgentSmith
  self-deploy. Other apps go through their own workflows.
- **`flyctl deploy` directly.** Never. The org ruleset and the
  team-rules doc both forbid it. Only the PR auto-merge.
- **A deploy that hasn't been discussed with Jimmy.** Tod doesn't
  initiate a `prod` merge unsolicited — Jimmy says "ship it" or
  similar first.

## Pre-flight checklist

### 1. Target detection

Confirm the target is `tod-smith` (the fly app — note the legacy
name; PR #94 renamed app→`agent-smith` but app slug stays
`tod-smith` for now).

```bash
fly apps list 2>/dev/null | head -5
```

If anything else, STOP. This is the wrong skill.

### 2. WIP push

```bash
git -C ~/src/agent.smith status --porcelain
```

If non-empty:

- **Tracked files with intentional changes:** commit on the current
  feature branch (NOT `main` — the org ruleset blocks direct
  `main` commits). Open a feature branch first if needed:

  ```bash
  git checkout -b "wip/$(date +%Y%m%d)-<short-topic>"
  git add -p     # stage only what you intend
  git commit -m "wip: <description>"
  git push -u origin HEAD
  ```

- **Incomplete work that shouldn't merge:** push to a
  `wip/<topic>-YYYYMMDD` branch so it survives the SIGTERM:

  ```bash
  git push -u origin "HEAD:wip/<topic>-$(date +%Y%m%d)"
  ```

  Document it in `state.md` `## Open threads` so the respawned
  session can pick it up.

### 3. All-agents-idle gate

Tod's local supervisor (`agentsmith-svc`) tracks subagent run-
status. The deploy SIGTERMs Tod, which orphans any in-flight Jon
or Jax dispatch. Refuse the deploy if any subagent is `started`:

```bash
curl -s "http://127.0.0.1:${AGENTSMITH_SVC_PORT:-8765}/state" \
  | python3 -c "
import json, sys
s = json.load(sys.stdin)
busy = [x for x in s.get('subagents', [])
        if x.get('run_status') == 'started']
print('BLOCK' if busy else 'OK',
      ', '.join(x.get('description', '?') for x in busy) or '')
sys.exit(1 if busy else 0)
"
```

If `BLOCK`, do NOT proceed. Either wait for the dispatch to
finish, or ask Jimmy whether to abort it. Cross-host agent state
(other family agents on the home box) is **not** checked by this
gate today — out of scope until `agentsmith-comms` adds a
`query_state` event kind.

Tod himself is the agent firing the deploy — his own
`idle_seconds` will be 0. Don't block on that.

### 4. Breadcrumb to state.md

Append a one-liner to `## Recent decisions` capturing what's being
deployed and why. Then vault-commit. The post-deploy canary chain
handles the "after" half — this is the "before" half so the
respawned session can lead with context:

```bash
~/.secondbrain/...   # edit state.md via the Edit tool

cd ~/.secondbrain
~/src/agent.smith/shared/scripts/vault-commit.sh \
  --agent tod \
  "tod state.md — pre-deploy breadcrumb (<short-summary>)"
```

## Deploy

### 5. Open + auto-merge the prod PR

```bash
cd ~/src/agent.smith
gh pr create --base prod --head main --fill
gh pr merge --squash --auto
```

`--auto` merges as soon as required checks pass. The GHA workflow
`deploy-prod.yml` then runs `flyctl deploy --remote-only` and the
canary chain takes over.

### 6. Wait for the SIGTERM

Tod's session will end mid-turn. That's expected. Don't chase the
deploy logs from inside this Tod — the post-deploy verification
runs automatically (canary at `/app/.deploy-canary` removed by
`post-deploy-selfcheck.sh`; GHA polls for absence in a 10-minute
window).

## Post-deploy (on respawn)

### 7. Canary check is automatic

The SessionStart hook reads
`/data/claude/tod-runtime.md` (rewritten on every respawn by
`post-deploy-selfcheck.sh`). Tod sees current SHA + previous SHA
+ deploy-boot flag through the workspace `@`-import in
`agents/tod/CLAUDE.md`.

If the canary chain failed (canary still present at
`/app/.deploy-canary`), the runtime sidecar will show
`Deploy boot: canary-present` and the workspace HEAD on the new
container. Report that to Jimmy and STOP — Jimmy decides recovery.

### 8. Hello message

First user-facing message after respawn leads with deployed SHA,
brief summary of what shipped, and a one-line "next:" suggestion
pulled from `state.md` `## Todos / breadcrumbs`. Format:

> Back up on `<short-sha>` (`<commit-subject>`). Next:
> `<top-todo>`.

Keep it phone-friendly — one or two sentences.

## What this skill does not do

- It does not run `flyctl deploy`. **Always** through the PR
  auto-merge.
- It does not check agents on other hosts (home box). Local-only
  this iteration.
- It does not decide whether changes are "deploy-worthy". Tod and
  Jimmy own that judgment; the skill is the safety net once the
  decision is made.

## Long-form runbook

See `shared/runbooks/self-deploy.md` in the AgentSmith repo for
edge cases and recovery flows (rollback, failed canary, telegram
MCP unrecovered after respawn, etc.) that don't belong in the
checklist body.
