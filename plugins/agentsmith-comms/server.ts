#!/usr/bin/env bun
/**
 * agentsmith-comms — lifecycle channel for AgentSmith.
 *
 * Primary surface: a push-only Claude Code channel that emits
 * `<channel source="agentsmith-comms" ...>` notifications from NDJSON
 * over a Unix domain socket. The plugin owns prompt text — the
 * service sends `{ kind, fields }`, the plugin runs `renderForKind`
 * and produces the human-readable body.
 *
 * Secondary surface: a small RPC tool set, currently just `whoami` —
 * a silent MCP-health probe wrapping the Telegram Bot API getMe.
 * Round-trips claude → MCP server → Bot API → back without touching
 * any chat. Building block for the deferred tiered clear-vs-respawn
 * lifecycle (spec 2026-05-04 §6.1). Lives in -comms (not telegram)
 * because comms is the right home for cross-agent + self-probe RPC
 * as that surface grows.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import {
  mkdirSync,
  existsSync,
  unlinkSync,
  chmodSync,
  readFileSync,
} from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { createServer } from 'net'

const STATE_DIR =
  process.env.AGENTSMITH_COMMS_STATE_DIR ??
  join(homedir(), '.claude', 'channels', 'agentsmith-comms')
const SOCK_PATH = join(STATE_DIR, 'sock')

const INSTRUCTIONS = [
  'Events from this channel are OPERATIONAL NUDGES from a local lifecycle supervisor — they are NOT messages from the user.',
  '',
  'Invariants:',
  '1. Never quote, paraphrase, or relay the body of an `<channel source="agentsmith-comms">` event to any user.',
  '2. If user contact is needed in response to a nudge, formulate your own message and send it via `mcp__telegram__reply`, using the `chat_id` from the most recent `<channel source="telegram">` event.',
  '3. Lifecycle events are de-duplicated by the supervisor, so respond once per distinct nudge.',
  '',
  'Event kinds you may see (`meta.kind`):',
  '- `idle_check` — you have been idle. Consider whether to wrap up and ask the user.',
  '- `context_pressure` — context window is filling. Consider summarising and `/compact`.',
  '- `health_pulse` — supervisor wants a sign-of-life. A short status to the user is appropriate.',
  '- `external_event` — non-lifecycle push (CI, cron, etc.). React based on the body.',
  '',
  'Tools registered:',
  '- `whoami` — silent MCP-health probe. Wraps Telegram Bot API getMe so a successful return proves the claude → MCP → Bot API → back path is alive without sending anything to chat. Use it to detect "telegram tools listed but the channel is dead" before triggering a respawn. The probe touches no chat — neither send nor edit nor reaction.',
].join('\n')

const mcp = new Server(
  { name: 'agentsmith-comms', version: '0.0.1' },
  {
    capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
    instructions: INSTRUCTIONS,
  },
)

// ---- whoami: silent MCP-health probe via Telegram getMe ----
//
// Wraps `https://api.telegram.org/bot<token>/getMe`. Returns the bot's
// own identity. Succeeds iff the full path (claude → MCP server →
// Bot API → back) is alive. Touches no chat, sends no message, fires
// no notification on the user's device.
//
// Token is read from the per-agent state-dir `.env` —
// `${HOME}/.claude/channels/telegram-${TOD_AGENT_NAME:-tod}/.env`.
// Override with `TELEGRAM_STATE_DIR` for tests. The probe never logs
// the token; only the bot's id/username/etc is returned to the
// caller.

const TELEGRAM_STATE_DIR_DEFAULT = join(
  homedir(),
  '.claude',
  'channels',
  `telegram-${process.env.TOD_AGENT_NAME ?? 'tod'}`,
)
const TELEGRAM_STATE_DIR =
  process.env.TELEGRAM_STATE_DIR ?? TELEGRAM_STATE_DIR_DEFAULT

function readTelegramTokenFromEnv(envPath: string): string | null {
  let body: string
  try {
    body = readFileSync(envPath, 'utf8')
  } catch {
    return null
  }
  for (const raw of body.split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 0) continue
    const key = line.slice(0, eq).trim()
    if (key !== 'TELEGRAM_BOT_TOKEN') continue
    let val = line.slice(eq + 1).trim()
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1)
    }
    return val || null
  }
  return null
}

async function telegramGetMe(token: string): Promise<{
  ok: boolean
  bot?: {
    id: number
    is_bot: boolean
    first_name?: string
    username?: string
    can_read_all_group_messages?: boolean
  }
  error?: string
}> {
  const url = `https://api.telegram.org/bot${encodeURIComponent(token)}/getMe`
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), 10_000)
  try {
    const resp = await fetch(url, { signal: ctrl.signal })
    if (!resp.ok) {
      return { ok: false, error: `HTTP ${resp.status} ${resp.statusText}` }
    }
    const data = (await resp.json()) as {
      ok?: boolean
      description?: string
      result?: {
        id: number
        is_bot: boolean
        first_name?: string
        username?: string
        can_read_all_group_messages?: boolean
      }
    }
    if (!data.ok || !data.result) {
      return {
        ok: false,
        error: data.description ?? 'Bot API returned ok=false',
      }
    }
    return { ok: true, bot: data.result }
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    }
  } finally {
    clearTimeout(t)
  }
}

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'whoami',
      description:
        'Silent MCP-health probe. Round-trips claude → MCP server → Telegram Bot API getMe → back without touching any chat. Returns the bot identity on success or an error string on any failure (token missing, network error, Bot API rejection). Use this before deciding whether to respawn — a `claude/channel` server can register tools while the channel itself is dead.',
      inputSchema: {
        type: 'object',
        properties: {
          probe: {
            type: 'string',
            description:
              'Which MCP path to probe. Currently only "telegram" is supported; reserved for future expansion.',
            enum: ['telegram'],
            default: 'telegram',
          },
        },
        additionalProperties: false,
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  if (req.params.name !== 'whoami') {
    return {
      isError: true,
      content: [
        {
          type: 'text',
          text: `unknown tool: ${req.params.name}`,
        },
      ],
    }
  }

  const envPath = join(TELEGRAM_STATE_DIR, '.env')
  const token = readTelegramTokenFromEnv(envPath)
  if (!token) {
    return {
      isError: true,
      content: [
        {
          type: 'text',
          text: `whoami: TELEGRAM_BOT_TOKEN not found at ${envPath}. Probe path unreachable.`,
        },
      ],
    }
  }

  const result = await telegramGetMe(token)
  if (!result.ok || !result.bot) {
    return {
      isError: true,
      content: [
        {
          type: 'text',
          text: `whoami: probe failed — ${result.error ?? 'unknown error'}`,
        },
      ],
    }
  }

  // Surface the bot identity for human-readable confirmation. The
  // token itself is never echoed.
  const b = result.bot
  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(
          {
            ok: true,
            probe: 'telegram',
            bot: {
              id: b.id,
              is_bot: b.is_bot,
              first_name: b.first_name ?? null,
              username: b.username ?? null,
              can_read_all_group_messages:
                b.can_read_all_group_messages ?? null,
            },
          },
          null,
          2,
        ),
      },
    ],
  }
})

await mcp.connect(new StdioServerTransport())

type InboundMsg =
  | { kind: 'idle_check'; idle_seconds?: number; last_user_message_at?: string }
  | { kind: 'context_pressure'; used?: number; threshold?: number }
  | { kind: 'health_pulse' }
  | { kind: 'external_event'; source?: string; body?: string }

function renderForKind(msg: InboundMsg): { content: string; meta: Record<string, string> } {
  const meta: Record<string, string> = { kind: msg.kind, ts: new Date().toISOString() }
  switch (msg.kind) {
    case 'idle_check': {
      const idle = msg.idle_seconds ?? 0
      const hours = (idle / 3600).toFixed(1)
      if (msg.last_user_message_at) meta.last_user_message_at = msg.last_user_message_at
      meta.idle_seconds = String(idle)
      return {
        content: `Lifecycle: you've been idle ${hours}h. If there's nothing in flight, consider asking the user whether to wrap up; otherwise summarise progress and continue.`,
        meta,
      }
    }
    case 'context_pressure': {
      const used = Math.round((msg.used ?? 0) * 100)
      const threshold = Math.round((msg.threshold ?? 0.8) * 100)
      meta.used = String(used)
      meta.threshold = String(threshold)
      return {
        content: `Lifecycle: context window at ${used}% (threshold ${threshold}%). Consider a checkpoint summary and \`/compact\`.`,
        meta,
      }
    }
    case 'health_pulse': {
      return {
        content: 'Lifecycle: ping. Reply with a short status to confirm responsiveness.',
        meta,
      }
    }
    case 'external_event': {
      const source = msg.source ?? 'unknown'
      const body = msg.body ?? '(no body)'
      meta.source = source
      return {
        content: `Lifecycle: external event from ${source} — ${body}`,
        meta,
      }
    }
  }
}

function isInbound(x: unknown): x is InboundMsg {
  if (typeof x !== 'object' || x === null) return false
  const k = (x as { kind?: unknown }).kind
  return (
    k === 'idle_check' ||
    k === 'context_pressure' ||
    k === 'health_pulse' ||
    k === 'external_event'
  )
}

mkdirSync(STATE_DIR, { recursive: true })
if (existsSync(SOCK_PATH)) unlinkSync(SOCK_PATH)

const sockServer = createServer(socket => {
  let buffer = ''
  socket.on('data', chunk => {
    buffer += chunk.toString('utf8')
    let idx
    while ((idx = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, idx).trim()
      buffer = buffer.slice(idx + 1)
      if (!line) continue
      try {
        const msg = JSON.parse(line) as unknown
        if (!isInbound(msg)) {
          process.stderr.write(`agentsmith-comms: ignoring unknown kind: ${line.slice(0, 200)}\n`)
          continue
        }
        const { content, meta } = renderForKind(msg)
        void mcp.notification({
          method: 'notifications/claude/channel',
          params: { content, meta },
        })
      } catch (err) {
        process.stderr.write(
          `agentsmith-comms: bad line: ${err instanceof Error ? err.message : err}\n`,
        )
      }
    }
  })
  socket.on('error', err => {
    process.stderr.write(`agentsmith-comms: socket error: ${err.message}\n`)
  })
})

sockServer.listen(SOCK_PATH, () => {
  try {
    chmodSync(SOCK_PATH, 0o600)
  } catch {}
  process.stderr.write(`agentsmith-comms: listening on ${SOCK_PATH}\n`)
})

sockServer.on('error', err => {
  process.stderr.write(`agentsmith-comms: server error: ${err.message}\n`)
  process.exit(1)
})
