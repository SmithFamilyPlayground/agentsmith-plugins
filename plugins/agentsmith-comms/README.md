# agentsmith-comms

Lifecycle channel plugin for AgentSmith. Push-only. The plugin lets a
local supervisor process (the lifecycle service, separate process) nudge
a long-running `claude` session about idle, context pressure, and
external events without going through the user-facing telegram channel.

> **Migration in progress (spec rev 8).** The v1 envelope contract
> ([`2026-05-08-agentsmith-comms-api-contract.md`][spec-v1]) is rolling
> out across three phases. Phase 0 (this PR) adds the test harness +
> golden smoke against today's v0.0.1 rendering. Phase 1 lands the v1
> envelope library + the v0.0.1 backward-compat shim under `lib/`.
> Phase 3 **retires this MCP server** in favour of Claude Code
> notification hooks (spec rev 8 §N, §X) — the `<channel
> source="agentsmith-comms">` wrapper format and the four lifecycle
> invariants stay; only the transport changes. The v0.0.1 inbound
> shape documented below is preserved through the shim for the full
> migration window (spec §9).
>
> [spec-v1]: https://github.com/SmithFamilyPlayground/AgentSmith/blob/main/docs/superpowers/specs/2026-05-08-agentsmith-comms-api-contract.md

## Why a second channel

User-facing comms run through the `telegram` plugin (`@claude-plugins-official`).
Lifecycle nudges have a different posture: not user messages, no reply
contract, and on `agentsmith-comms` no tools at all. Decoupling makes
the lifecycle path independent of whichever user-facing surface is
current — when telegram is replaced later by a Tailscale-gated rich
client, this channel is unaffected.

See `docs/agentsmith-svc/` in the [AgentSmith
repo](https://github.com/SmithFamilyPlayground/AgentSmith) for the full
architecture write-up.

## Shape

- **Server name:** `agentsmith-comms` → claude sees events as `<channel
  source="agentsmith-comms" ...>`.
- **Capabilities:** `experimental['claude/channel']: {}` only. No `tools`,
  no `claude/channel/permission`.
- **Transport (inbound from supervisor):** Unix domain socket at
  `~/.claude/channels/agentsmith-comms/sock` (override with
  `AGENTSMITH_COMMS_STATE_DIR`).
- **Wire format:** newline-delimited JSON, one message per line.
- **Rendering:** the plugin owns prompt text via `renderForKind`; the
  supervisor sends `{ kind, ...fields }`, the plugin produces the body
  claude reads.

## Event kinds (initial set)

| `kind` | Inbound JSON | Rendered body |
| --- | --- | --- |
| `idle_check` | `{ kind: "idle_check", idle_seconds: 14400, last_user_message_at: "..." }` | `Lifecycle: you've been idle 4.0h. If there's nothing in flight, ...` |
| `context_pressure` | `{ kind: "context_pressure", used: 0.82, threshold: 0.80 }` | `Lifecycle: context window at 82% (threshold 80%). ...` |
| `health_pulse` | `{ kind: "health_pulse" }` | `Lifecycle: ping. Reply with a short status to confirm responsiveness.` |
| `external_event` | `{ kind: "external_event", source: "ci", body: "..." }` | `Lifecycle: external event from ci — ...` |

The body always begins with the literal token `Lifecycle:` so any
accidental leakage to the user is visually obvious.

## Install

Marketplace: `agentsmith-plugins`. Once published, wire on launch:

```sh
claude --channels plugin:telegram@claude-plugins-official \
                  plugin:agentsmith-comms@agentsmith-plugins
```

## Sending a manual nudge

```sh
echo '{"kind":"health_pulse"}' | nc -U ~/.claude/channels/agentsmith-comms/sock
```

`mcp__agentsmith-comms__*` tools do **not** exist — the plugin is
push-only. To respond, claude uses tools on other channels (typically
`mcp__telegram__reply` for user-facing replies).

## Tests

Run the bun-test harness from the plugin root:

```sh
bun install
bun test
```

`test/v001-shim.test.ts` is the golden smoke for today's v0.0.1
rendering output (spec rev 8 §9). It spawns `server.ts` against a
temp UDS, sends each of the four v0.0.1 inbound kinds, and locks the
rendered `notifications/claude/channel` content byte-for-byte. The
Phase 1 backward-compat shim and the Phase 3 `comms-render` CLI are
measured against the same expectations.
