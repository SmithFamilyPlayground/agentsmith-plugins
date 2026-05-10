---
name: claude-persistent-memory
description: Use when a Claude Code persistent-identity agent (a long-running session whose continuity-of-self matters across sessions) needs to read or write its own memory — state.md continuity, recall lookups, consolidation notes, archival of conversation context. Phase-1a MVP — bundles a `local-vault` CLI that implements the Memory.* contract against a local project vault at `<project>/.claude-persistent-memory/`. Standalone — no svc, no agentsmith-api required. The dreaming-model hooks (recall.sh, consolidate-and-restart, context-pressure) are deferred to phase-1b; this phase just ships the contract surface so consumer code can be exercised end-to-end.
---

# claude-persistent-memory — phase-1a MVP

A Claude Code plugin that gives persistent-identity agents (e.g. Tod
in AgentSmith mode; any solo-user project-coach in standalone mode) a
durable, queryable, append-friendly memory.

This phase (1a) is the **standalone slice**. It ships the
`local-vault` CLI that backs the `Memory.*` contract against a local
project vault at `<project>/.claude-persistent-memory/`. The plugin's
hooks (recall, consolidate-and-restart, context-pressure) are
deferred to phase-1b; the AgentSmith-api integration is deferred to
phase-1c.

## Why this exists

Continuity of self for an agent across sessions requires three
things:

1. A stable place to read its current state at session start
   (`state.md`).
2. A way to fetch detail not in state when a turn needs it
   (`recall`).
3. A way to periodically rewrite state from session evidence
   (`consolidate-and-restart`).

The plugin defines all three layers. Phase-1a ships **only** the
storage substrate (the `local-vault` CLI) so phase-1b can wire the
hooks on top of a working Memory.* implementation.

## What ships in phase-1a

```
plugins/claude-persistent-memory/
├── .claude-plugin/plugin.json
├── skills/claude-persistent-memory/SKILL.md   (this file)
├── cli/local-vault.sh                         (Memory.* implementation)
├── lib/                                       (helper functions sourced by the CLI)
│   ├── store.sh
│   ├── recall.sh
│   ├── update.sh
│   ├── list.sh
│   └── config.sh
└── tests/smoke.sh                             (end-to-end exercise of every subcommand)
```

No hooks, no MCP server, no install.sh / uninstall.sh in 1a — those
land in phase-1b alongside the dreaming-model layers.

## The `local-vault` CLI — Memory.* against a local vault

`local-vault` is a self-contained bash CLI. Default vault location:
`<project>/.claude-persistent-memory/`. Override with `--path` or the
`CPM_VAULT_PATH` env var.

### `local-vault init [--path <dir>] [--identity <slug>]`

Scaffolds a fresh vault. Creates the directory, writes a stub
`config.toml`, creates the per-identity subdirectory tree (default
identity `default`), and initialises `state.md` with empty sections.

If the cwd is inside a git repo and `commit_shape = "git"` (the
default), no extra git init happens — writes commit on the current
branch. If `commit_shape = "git"` but the cwd is **not** a git repo,
`init` warns and defaults to `commit_shape = "none"`.

### `local-vault store <content> [--topic <t>] [--privacy <p>] [--slot <s>] [--kind <k>]`

Backs `Memory.Store(content, hints)`. Writes content to disk under
the per-identity directory, generates the frontmatter envelope, and
(in `git` shape) creates a commit. Emits the resolved `memory_id` on
stdout — a stable handle of the form `<slot>/<kind>/<id>` where `id`
is timestamp-derived.

Hints:

- `--slot <s>` — identity slug. Defaults to the config's
  `default_identity` (set at `init` time).
- `--kind <k>` — `state` / `summary` / `note` / `archive`. Default
  `note`. `state` is special-cased: a single canonical document at
  `<slot>/state.md` (overwrites on subsequent stores). `summary`
  files under `<slot>/topics/<topic>.md` (overwrites the topic file).
  `note` files under `<slot>/notes/<id>.md` (append-style;
  monotonic). `archive` files under
  `<slot>/conversations/<YYYY>/<MM>/<id>.md`.
- `--topic <t>` — required for `kind=summary`; otherwise filed as
  the frontmatter `topic:` field.
- `--privacy <p>` — `public` / `family-internal` / `private`.
  Default `family-internal`. Recorded in frontmatter only —
  recall-time filtering is deferred.
- Content can be passed as the positional arg or read from stdin if
  the positional is omitted (or `-`).

The CLI generates the frontmatter (the plugin's caller never writes
frontmatter — per cpm spec §3.1 + api spec §M.3 "schema enforced
INSIDE Memory.*"). Generated fields:

```yaml
---
type: cpm-state | cpm-summary | cpm-note | cpm-archive
slot: <identity-slug>
kind: <kind>
topic: <topic-or-null>
privacy: <privacy>
created: <UTC ISO8601>
updated: <UTC ISO8601>
memory_id: <slot>/<kind>/<id>
---
```

### `local-vault recall <query> [--scope summary|all-by-topic] [--slot <s>]`

Backs `Memory.Recall(query, scope_flags)`. Walks the vault fresh on
every call (no cache — per overview rev 3 §8.2 / Jimmy msg 741) and
returns matching documents.

- Default scope `summary` — returns a brief listing (path + first
  paragraph) of the top matches.
- `--scope all-by-topic` — returns the full content of every
  topic-file matching the query.

Phase-1a uses a simple `grep`-based match against content +
frontmatter. Smarter semantic recall is deferred — the spec puts
recall in a subagent surface (Layer B), not in the CLI itself.

### `local-vault update <memory_id> <patch>`

Backs `Memory.Update(memory_id, patch)`. Resolves `memory_id` to a
disk path, applies the patch (default: replace body wholesale; patch
can also be read from stdin), bumps the `updated:` frontmatter
timestamp, commits if `commit_shape = "git"`. Emits the (unchanged)
`memory_id` on stdout.

### `local-vault list [--filter <f>] [--slot <s>]`

Backs `Memory.List(filter)`. Emits one `memory_id` per line, one per
file in the slot. `--filter` matches against memory_id + topic +
kind.

### `local-vault config`

Backs `Memory.Config()`. Emits JSON with default thresholds and
triggers. v1 payload mirrors api spec §M.4 (so callers can write
against one shape across both backends).

## On-disk layout (default after `init`)

```
<project>/.claude-persistent-memory/
├── config.toml
└── <identity-slug>/
    ├── state.md
    ├── topics/
    ├── notes/
    └── conversations/
```

Phase-1b adds `consolidation-log/`, `cold-archive/`, and
`.dreaming.lock`.

## Standalone mode — current and only mode in phase-1a

Phase-1a does NOT auto-detect `agentsmith-api`. There is no api
plugin yet. The CLI is always used directly. Phase-1c (after the api
plugin lands) wires the auto-detect + the routing through `Memory.*`
MCP tools.

If you're in AgentSmith and somehow loaded this plugin today, it
will still work — it just won't replace any AgentSmith memory paths.
The `agentsmith_api.subagent_memory_lifecycle: false` toggle
mentioned in cpm spec §11.1 is a phase-1c concern.

## What's NOT in phase-1a

Explicit deferral list — phase-1b / phase-1c follow-ups:

- The dreaming-model hooks (Layer B recall.sh subagent prompt, Layer
  C consolidate-and-restart orchestrator, Layer D context-pressure
  UserPromptSubmit hook). All deferred to phase-1b.
- `should-dream.sh` gate + the consolidator prompt templates.
- `install.sh` / `uninstall.sh` (workspace `CLAUDE.md` @-import
  wiring). Deferred to phase-1b — the operator wires the @-import
  manually for now.
- Auto-detection of an `agentsmith-api` backend. Deferred to
  phase-1c (agentsmith-api doesn't exist yet).
- Haiku-driven PII / secrets scan on writes. Spec §9.4 explicitly
  excludes this from the standalone CLI; it stays in
  `agentsmith-api`'s lane (api spec §V.4).
- Today-branch flow. Local commits go to the current branch
  unconditionally (spec §9.4 — single-writer assumption).
- `commit_shape = "git-branch"` (writes land on a dedicated branch
  like `claude-persistent-memory/today`) is **NOT** implemented in
  phase-1a; flagged TBD-phase-1b in `config.toml.example`.
  `commit_shape = "none"` (file-system writes only, no git
  involvement) **IS** supported — `init` falls back to it
  automatically when no enclosing git repo is found, and an
  operator can set it explicitly. Default `commit_shape = "git"`
  is fully implemented and is the path the smoke test exercises.
- Privacy enforcement at recall time. Privacy is a frontmatter tag
  for human pruning only.
- Cross-vault federation reads (single-vault only).
- Multi-identity recall fan-out.
- `dry_run` and `mode` hints from api spec §M.2 — `dry_run` is the
  meta-agent review-required-consolidation path (Layer C, phase-1b);
  `mode` is the api-side backend router (phase-1c). Neither is
  needed in phase-1a since the CLI is invoked directly.

## How to use the CLI standalone (phase-1a operator runbook)

```bash
# in the project root
./plugins/claude-persistent-memory/cli/local-vault.sh init --identity me

# store a memory
./plugins/claude-persistent-memory/cli/local-vault.sh store "first decision" --kind note --topic kickoff

# overwrite state.md
echo "## Current focus" \
  | ./plugins/claude-persistent-memory/cli/local-vault.sh store - --kind state

# list everything
./plugins/claude-persistent-memory/cli/local-vault.sh list

# recall
./plugins/claude-persistent-memory/cli/local-vault.sh recall "kickoff"

# show config
./plugins/claude-persistent-memory/cli/local-vault.sh config
```

Wire `state.md` into the workspace `CLAUDE.md` by hand for now:

```
@<project>/.claude-persistent-memory/me/state.md
```

(Phase-1b's `install.sh` will automate this.)

## Spec references

- Spec rev 2 — `docs/superpowers/specs/2026-05-10-claude-persistent-memory.md`
  (especially §1, §2, §9, §10 in AgentSmith repo).
- api Memory.* contract — `docs/superpowers/specs/2026-05-08-agentsmith-comms-api-contract.md`
  §M (the contract this CLI implements against a local vault).
- Architecture overview — `docs/architecture/overview.md` §5
  (claude-persistent-memory), §9.8 (toggle, post-1c).

## Related

- `agentsmith-vault` skill — the AgentSmith-mode Memory.* backend.
  Same contract shape, different vault path. Lifts into
  `agentsmith-api` post-rev-2.
