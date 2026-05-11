---
name: agentsmith-api
description: Use when an AgentSmith family agent needs to write to / read from the SecondBrain vault, dispatch a closed-set fix-concern subagent, look up routes, or wire in the always-on subagent-tools hooks. Implements the Memory.* contract surface, owns vault-IO via the bundled `vault-commit.sh` (today-branch + raw/-immutable + retry-with-rescue-ref), exposes Dispatch.Agent as a filesystem-queue rendezvous when svc is unreachable, and ships the defensive + always-on subagent hooks. Standalone — works without agentsmith-svc.
---

# agentsmith-api — phase-2a MVP

The AgentSmith family API plugin. Bundles the contract surfaces that
the rest of the family consumes: `Memory.*` (used by
`claude-persistent-memory` when AgentSmith mode is active), vault-IO
(every per-write path to `~/.secondbrain`), routes-cache (used by
the route-guard hook and by anything that needs to know "what paths
can this agent write to"), `Dispatch.Agent` (Tod's closed-set
fix-concerns surface), and the subagent-tools (ex-lifecycle) hook
surface.

Phase-2a is the **standalone slice**. It ships the CLI surfaces and
the always-run hooks that the rest of the family can depend on,
even when `agentsmith-svc` is unreachable. svc is a graceful
fallback path, not a hard dependency.

## Why this exists

Per agentsmith-comms-api-contract spec §A (the rev-2 architectural
rule): **agentsmith-api owns vault-IO and the Memory.* surface;
agentsmith-svc owns runtime-shared state.** Vault writes don't
proxy through svc, so the family keeps writing to the vault when
svc is down. That property is the architectural backbone of the
rev-2 reshape, and it lives here.

The plugin also folds in the ex-`agentsmith-lifecycle` subagent-
tools surface (defensive hooks + route-guard + signal-handler
stubs), so the always-on trust boundary travels with the api
plugin instead of needing a separate install.

## What ships in phase-2a

```
plugins/agentsmith-api/
├── .claude-plugin/plugin.json
├── skills/agentsmith-api/SKILL.md           (this file)
├── cli/
│   ├── memory.sh                            (Memory.* implementation)
│   ├── vault-commit.sh                      (bundled per-write path)
│   ├── routes.sh                            (routes cache + bundled fallback)
│   └── dispatch.sh                          (Dispatch.Agent filesystem queue)
├── lib/                                     (helper functions sourced by CLIs)
│   ├── ids.sh
│   ├── frontmatter.sh
│   ├── store.sh
│   ├── recall.sh
│   ├── update.sh
│   ├── list.sh
│   ├── config.sh
│   └── routes.sh
├── hooks/                                   (defensive + route-guard hooks)
│   ├── route-guard.sh
│   ├── block-secret-writes.sh
│   ├── shellcheck-edits.sh
│   ├── binary-sync-reminder.sh
│   ├── validate-settings-json.sh
│   ├── routing-loaded-emitter.sh            (toggle-gated stub)
│   └── signal-handler.sh                    (toggle-gated stub)
└── tests/smoke.sh                           (end-to-end exercise of every surface)
```

No MCP server, no install.sh / uninstall.sh in 2a — see "Deferred to
phase-2b" below.

## The `memory.sh` CLI — Memory.* against `~/.secondbrain`

`memory.sh` is the AgentSmith-mode backend for the Memory.* contract
defined in api spec §M. Same five-subcommand shape as
`claude-persistent-memory`'s `local-vault` CLI (`init` /
`store` / `recall` / `update` / `list` / `config`) but routes the
per-write path through the bundled `vault-commit.sh`, so writes
land on the long-lived `today` branch with `raw/`-immutability
enforced and per-agent bot-identity attribution.

### `memory.sh store <content> [--kind k] [--topic t] [--slot s] [--privacy p] [--scan-mode m] [--mode m]`

Writes a memory under `~/.secondbrain/10_agents/<slot>/` (the
`agentsmith` meta-agent special-cases to vault root per spec §8.2)
and commits via `vault-commit.sh`. Same kind semantics as
`local-vault` — `state` overwrites a canonical doc, `summary`
overwrites per-topic, `note` appends, `archive` files under
YYYY/MM. Frontmatter shape matches api spec §V.2 (api-side names:
`type` derived from kind, `agent` from slot, `updated`, `topic`
when summary, `privacy`).

Flags:

- `--slot <s>` — identity slug. Defaults to `${TOD_AGENT_NAME:-tod}`.
- `--kind <k>` — `state | summary | note | archive`. Default `note`.
- `--topic <t>` — required for `kind=summary`.
- `--privacy <p>` — `public | family-internal | private`. Default
  `family-internal`. Preserved on re-store if not passed.
- `--scan-mode {full,skip}` — Haiku PII/secrets scan (spec §V.4).
  Phase-2a stubs this: `skip` is the default; `full` warns "Haiku
  scan not yet implemented; treating as skip" and continues. Flag
  preserved for the phase-2b implementation.
- `--mode {today,local}` — `today` (AgentSmith default; writes
  through `vault-commit.sh`) or `local` (passthrough — no
  today-branch checkout, no push; commits on current branch where
  the slot lives, for tests + non-AgentSmith vaults).
- `--vault <path>` — override `VAULT_PATH` (default
  `~/.secondbrain`).

Emits `memory_id` (`<slot>/<kind>/<id>`) on stdout.

### `memory.sh recall <query> [--scope summary|all-by-topic] [--slot s]`

Walks the configured vault fresh on every call (no cache — per
overview rev 3 §8.2). Returns matching documents under
`<vault>/10_agents/<slot>/`. Phase-2a uses `grep`-based fixed-
string matching; smarter semantic recall lives in cpm's Layer B
subagent, not here.

### `memory.sh update <memory_id> [<patch>]`

Resolves `memory_id` to a disk path under the AgentSmith layout,
replaces the body wholesale, bumps `updated:` in frontmatter,
commits via `vault-commit.sh`. Patch from stdin if positional
omitted or `-`. Same memory_id validation as the cpm CLI — explicit
newline rejection + whole-string regex match (`[A-Za-z0-9._-]+`).

### `memory.sh list [--filter f] [--slot s]`

Emits one `memory_id` per line under the slot.

### `memory.sh config`

Returns JSON matching api spec §M.4. Defaults:

```json
{
  "contract_version": "agentsmith-api/1.0",
  "backend": "agentsmith-vault",
  "backend_version": "agentsmith-api/0.1.0-phase2a",
  "thresholds": {
    "active_context_pct": 0.30,
    "idle_auto_minutes": 90,
    "idle_auto_context_pct": 0.40
  },
  "intervals": {
    "plan_usage_refresh_minutes": 5,
    "state_md_freshness_warning_hours": 24
  },
  "triggers": {
    "consolidate_on_session_end": true,
    "consolidate_on_topic_boundary": true,
    "auto_restart_in_flight_subagents_blocked": true
  },
  "model_overrides": {}
}
```

The same `contract_version` cpm emits, so consumer code can speak to
either backend with a single shape.

## The `vault-commit.sh` CLI — per-write path

A bundled copy of the existing AgentSmith `shared/scripts/vault-
commit.sh` (the today-branch, stash-aware, retry-with-rescue-ref
helper). Two flags added per spec §V.1:

- `--scan-mode {full,skip}` — selects the §V.4 Haiku scan.
  Phase-2a accepts the flag but stubs the scan; `full` warns and
  proceeds.
- `--mode {today,local}` — `today` (default) runs the full today-
  branch checkout + push; `local` skips branch ops (`memory.sh` uses
  `local` against test vaults to avoid stomping the real flow).

Spec §V.3 holds: `vault-commit.sh` reads the local routes cache
(or bundled defaults when the cache is absent), so the per-write
path doesn't depend on svc.

## The `routes.sh` CLI — local routes cache + bundled fallback

```
routes.sh get [--slug <slug>] [--force-refresh] [--vault <path>]
routes.sh validate <path> [--slug <slug>]
routes.sh refresh                  (Phase-2b — hits svc; stubbed in 2a)
```

- `routes.sh get` writes (and reads) a per-session JSON snapshot at
  `${TMPDIR:-/tmp}/agentsmith-api/<agent>-<session-id>.routes.json`
  (atomic via temp + `mv`). If the cache is absent or `--force-
  refresh` is passed, Phase-2a falls back to the bundled defaults
  (spec §8.2). When svc lands, `refresh` will round-trip the HTTP
  endpoint.
- `routes.sh validate <path>` returns 0 if the given path is
  writable for the slug, non-zero otherwise. Used by
  `vault-commit.sh` for slot-validation (api spec §V.2 step 1)
  and by `hooks/route-guard.sh` for PreToolUse enforcement.

The bundled defaults match spec §8.2 verbatim — Tod, agentsmith
(meta-agent: vault-root special case), jon, jax, jef. Sam / Amy /
Ema are deferred (spec §8.4 — "not scaffolded in v1").

## The `dispatch.sh` CLI — Dispatch.Agent filesystem queue

```
dispatch.sh agent <role> --brief <path-or-->  [--spec-owner tod|jon]
                                              [--interactive true|false]
                                              [--automerge true|false]
                                              [--queue-dir <dir>]
dispatch.sh poll <dispatch_id>
dispatch.sh subscribe <dispatch_id>           (Phase-2b — streams; stubbed in 2a)
```

In standalone mode (no svc), `agent` writes the request to
`${TMPDIR:-/tmp}/agentsmith-api/dispatch/<dispatch_id>.request.json`
and emits the `dispatch_id` on stdout. The actual spawn is whatever
the operator does next — feed the JSON to svc, hand it to Tod, or
run the dispatched agent locally. `poll` reads from a sibling
`<dispatch_id>.status.json` if it exists (which the operator or svc
writes); otherwise it returns `pending`.

This is the "Tod-asks-AgentSmith via api.DispatchAgent" path
(spec §A heuristic), folded into a filesystem rendezvous for
v1. Spec §7.4 spawn semantics (request → accepted | refused →
complete) round-trip through this queue when svc is present;
v1 just persists the request.

## The hooks — defensive + always-on + toggle-gated stubs

The plugin ships hooks at `hooks/`. Wiring is a phase-2b concern
(install.sh maps them into the agent's `.claude/settings.json`);
phase-2a ships the scripts so they're available for direct
registration today.

**Always-run (regardless of toggle, per spec §L.3.1):**

- `route-guard.sh` (PreToolUse Edit|Write|MultiEdit|NotebookEdit|
  Bash) — reads the routes cache; fails closed on cache miss /
  parse error / unknown slug. Security primitive.

**Always-run defensive (universal, per spec §L.2):**

- `block-secret-writes.sh` (PreToolUse Edit|Write) — refuses
  writes to `.env` / `secrets/` / `*.pem` / `*.key` paths or
  content matching token/secret patterns. Same shape as Smith's
  root-scope hook.
- `shellcheck-edits.sh` (PostToolUse Edit|Write) — runs shellcheck
  on edited shell scripts. Soft-fail; warnings to stderr.
- `binary-sync-reminder.sh` (PostToolUse Edit|Write) — nudges when
  Dockerfile / homebox-setup / web-setup edited without sibling.
- `validate-settings-json.sh` (PostToolUse Edit|Write) — JSON-
  validates edited `settings*.json` files.

**Toggle-gated stubs (spec §L.3.2):**

- `routing-loaded-emitter.sh` (SessionStart) — Phase-2a calls
  `routes.sh get` and writes the cache, but doesn't emit on the
  wire (no svc + no MCP). Phase-2b adds the
  `lifecycle.routing_loaded` envelope emission.
- `signal-handler.sh` (Stop + UserPromptSubmit) — Phase-2a stub;
  exits 0. Phase-2b drains the per-agent comms buffer.

Toggle reading happens from the agent's `.claude/settings.json` at
the `agentsmith_api.subagent_memory_lifecycle` key. Default
`true` (sub-agent shape); parents (Tod, meta-agent) flip `false`
so cpm owns the memory lifecycle. The toggle-gated stubs check
the toggle and no-op when `false`.

## What's NOT in phase-2a

Explicit deferral list — phase-2b follow-ups:

- **MCP server (TypeScript / `@modelcontextprotocol/sdk`).**
  Spec §W's MCP-tool surface (`GetState`, `GetRoutes`, `Memory.*`,
  `Dispatch.*`, etc.) needs a TS server matching `agentsmith-comms`'s
  shape. Phase-2a's consumer surface is the CLI; consumers
  (today: `claude-persistent-memory` phase-1c) shell out to it.
  Phase-2b adds the MCP server.
- **HTTP POST to svc** (spec §6.2) for `agent_to_service` token
  reports, plan-usage, and `spawn.request`. Phase-2a's
  `dispatch.sh` writes the request to a filesystem queue;
  phase-2b POSTs it.
- **`routes.sh refresh` against svc**. Phase-2a uses bundled
  defaults; phase-2b hits `/api/v1/routes/<slug>`.
- **Haiku PII/secrets scan** (spec §V.4). Flag preserved
  (`--scan-mode full|skip`); implementation stubbed with a warn.
  Until phase-2b, the regex-layer `block-secret-writes.sh` is the
  only defence — same posture as today's GHA Claude semantic scan
  (which retires once Haiku ships).
- **`archive-session.sh`** (toggle-gated session-end hook per
  spec §L.3.2). The existing per-agent hook at
  `agent.smith/shared/hooks/archive-session.sh` is wired in
  parallel today; the plugin's own copy lands in phase-2b along
  with `install.sh`.
- **Wire-protocol envelopes** (spec §3-§7 — signals, state, token,
  lifecycle nudges, spawn). The existing `agentsmith-comms`
  plugin ships the v0.0.1 lifecycle nudges over UDS; the v1
  envelope migration lands when the MCP server lands.
- **`install.sh` / `uninstall.sh`** (workspace `CLAUDE.md` @-
  import + `.claude/settings.json` hook wiring). Phase-2b — the
  operator wires this manually for now.
- **`.claude/settings.json` toggle reader** in the hooks. Phase-
  2a's toggle-gated stubs check `subagent_memory_lifecycle` by
  reading `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json`
  (best-effort `jq` if present, fallback to a grep heuristic) —
  good enough for phase-2a where the stubs are no-ops anyway.
- **Decommission of `agent.smith/shared/scripts/vault-commit.sh`.**
  Out of scope for this PR per the dispatch brief — that's
  Phase-3 (the migration of the current memory system into the
  api surface).

## Standalone-vs-AgentSmith mode

This plugin is AgentSmith-focused — the default `--vault` is
`~/.secondbrain`. The `--mode local` flag exists for tests and
for symmetry with the api spec §V.1 backend selector, but the
local-vault sibling (the cpm bundled CLI) is the right tool for
non-AgentSmith projects. Phase-1c of cpm auto-detects which
backend to route through.

## Spec references

- api spec — `docs/superpowers/specs/2026-05-08-agentsmith-comms-
  api-contract.md` §A, §M, §V, §L, §W in the AgentSmith repo.
- cpm spec — `docs/superpowers/specs/2026-05-10-claude-persistent-
  memory.md` §M (the consumer expectations this api plugin must
  satisfy).
- Architecture overview — `docs/architecture/overview.md` rev 3
  (the cross-plugin context).
- Phase 1a reference — `plugins/claude-persistent-memory/` in
  this repo (the Memory.* shape consumer side; the
  api Memory.* surface must speak the same contract).

## Related

- `claude-persistent-memory` — the consumer plugin. Speaks
  Memory.* via cpm's bundled `local-vault` CLI today; phase-1c
  auto-detects this api plugin and routes Memory.* here when
  AgentSmith mode is active.
- `agentsmith-comms` — the wire-only lifecycle channel plugin.
  v0.0.1 UDS nudges. v1 envelope migration lands when the api
  plugin's MCP server lands (phase-2b).
- `agentsmith-vault` — the legacy skill that documented the
  AgentSmith vault-write contract. Folds into this plugin; the
  legacy skill stays in place for the rev-2 transition period
  and retires once `install.sh` lands.
