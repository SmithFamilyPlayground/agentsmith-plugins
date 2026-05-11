/**
 * Phase 0 golden smoke test — regression oracle for v0.0.1 line rendering.
 *
 * Spawns `server.ts` as a subprocess, sends each of the four v0.0.1 inbound
 * kinds over its UDS, and captures the JSON-RPC `notifications/claude/channel`
 * frames emitted on stdout. Asserts the rendered `content` byte-for-byte and
 * the `meta` shape (excluding the volatile `ts` field).
 *
 * This test is intentionally tight — it locks today's `server.ts` rendering
 * output so Phase 1's v0.0.1 backward-compat shim and Phase 3's
 * `comms-render` CLI can be measured against the same byte-level expectations
 * (spec rev 8 §9, impl plan §2).
 *
 * v0.0.1 inbound shape: `{ kind, ...fields }` over NDJSON on the UDS.
 * v0.0.1 rendered output: a `notifications/claude/channel` JSON-RPC frame
 * carrying `{ content, meta }` where `content` is human-readable prose and
 * `meta` is a string-valued record including `kind` and `ts`.
 */

import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawn, type Subprocess } from 'bun'
import { existsSync, mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { connect } from 'net'

const PLUGIN_ROOT = join(import.meta.dir, '..')
const SERVER_PATH = join(PLUGIN_ROOT, 'server.ts')

type ChannelNotification = {
  jsonrpc: '2.0'
  method: 'notifications/claude/channel'
  params: { content: string; meta: Record<string, string> }
}

type ServerHandle = {
  proc: Subprocess<'pipe', 'pipe', 'pipe'>
  sockPath: string
  stateDir: string
  notifications: ChannelNotification[]
  waitFor: (predicate: (n: ChannelNotification) => boolean, timeoutMs?: number) => Promise<ChannelNotification>
}

let handle: ServerHandle

async function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

async function startServer(): Promise<ServerHandle> {
  const stateDir = mkdtempSync(join(tmpdir(), 'agentsmith-comms-test-'))
  const sockPath = join(stateDir, 'sock')

  const proc = spawn({
    cmd: ['bun', SERVER_PATH],
    env: {
      ...process.env,
      AGENTSMITH_COMMS_STATE_DIR: stateDir,
    },
    cwd: PLUGIN_ROOT,
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  })

  const notifications: ChannelNotification[] = []

  // Drain stdout: each line is a JSON-RPC frame from StdioServerTransport.
  void (async () => {
    const decoder = new TextDecoder()
    let buf = ''
    if (!proc.stdout) return
    for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
      buf += decoder.decode(chunk, { stream: true })
      let idx: number
      while ((idx = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, idx).trim()
        buf = buf.slice(idx + 1)
        if (!line) continue
        try {
          const msg = JSON.parse(line) as ChannelNotification
          if (msg && msg.method === 'notifications/claude/channel') {
            notifications.push(msg)
          }
        } catch {
          // ignore non-JSON noise on stdout
        }
      }
    }
  })()

  // Drain stderr to keep the pipe from filling; ignore content.
  void (async () => {
    if (!proc.stderr) return
    for await (const _ of proc.stderr as ReadableStream<Uint8Array>) {
      // discard
    }
  })()

  // Wait for the UDS to appear (server's listen callback creates it) AND
  // accept a connection. Poll on file existence first, then probe.
  const deadline = Date.now() + 10000
  let ready = false
  while (Date.now() < deadline) {
    if (existsSync(sockPath)) {
      try {
        await new Promise<void>((resolve, reject) => {
          const c = connect(sockPath)
          c.once('connect', () => {
            c.end()
            resolve()
          })
          c.once('error', err => reject(err))
        })
        ready = true
        break
      } catch {
        // socket exists but not yet accepting; keep polling
      }
    }
    await sleep(50)
  }
  if (!ready) {
    throw new Error(`server UDS did not appear at ${sockPath} within 10s`)
  }

  const waitFor = async (
    predicate: (n: ChannelNotification) => boolean,
    timeoutMs = 2000,
  ): Promise<ChannelNotification> => {
    const start = Date.now()
    while (Date.now() - start < timeoutMs) {
      const hit = notifications.find(predicate)
      if (hit) return hit
      await sleep(10)
    }
    throw new Error(
      `timed out waiting for notification; captured kinds so far: ${notifications.map(n => n.params.meta.kind).join(', ') || '(none)'}`,
    )
  }

  return { proc, sockPath, stateDir, notifications, waitFor }
}

function stopServer(h: ServerHandle): void {
  try {
    h.proc.kill('SIGTERM')
  } catch {
    // already dead
  }
  try {
    rmSync(h.stateDir, { recursive: true, force: true })
  } catch {
    // best effort
  }
}

async function sendLine(sockPath: string, payload: object): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const c = connect(sockPath)
    c.once('connect', () => {
      c.end(JSON.stringify(payload) + '\n', () => resolve())
    })
    c.once('error', err => reject(err))
  })
}

beforeAll(async () => {
  handle = await startServer()
})

afterAll(() => {
  stopServer(handle)
})

describe('v0.0.1 line shape — golden smoke (spec rev 8 §9)', () => {
  test('idle_check renders fixed prose with idle_seconds folded into meta', async () => {
    await sendLine(handle.sockPath, {
      kind: 'idle_check',
      idle_seconds: 14400,
      last_user_message_at: '2026-05-11T10:00:00.000Z',
    })
    const n = await handle.waitFor(x => x.params.meta.kind === 'idle_check')
    expect(n.method).toBe('notifications/claude/channel')
    expect(n.params.content).toBe(
      "Lifecycle: you've been idle 4.0h. If there's nothing in flight, consider asking the user whether to wrap up; otherwise summarise progress and continue.",
    )
    expect(n.params.meta.kind).toBe('idle_check')
    expect(n.params.meta.idle_seconds).toBe('14400')
    expect(n.params.meta.last_user_message_at).toBe('2026-05-11T10:00:00.000Z')
    expect(typeof n.params.meta.ts).toBe('string')
    expect(n.params.meta.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)
  })

  test('context_pressure renders percentage prose with used + threshold in meta', async () => {
    await sendLine(handle.sockPath, {
      kind: 'context_pressure',
      used: 0.82,
      threshold: 0.8,
    })
    const n = await handle.waitFor(x => x.params.meta.kind === 'context_pressure')
    expect(n.params.content).toBe(
      'Lifecycle: context window at 82% (threshold 80%). Consider a checkpoint summary and `/compact`.',
    )
    expect(n.params.meta.used).toBe('82')
    expect(n.params.meta.threshold).toBe('80')
    expect(n.params.meta.kind).toBe('context_pressure')
  })

  test('health_pulse renders the fixed ping prose with only kind+ts in meta', async () => {
    await sendLine(handle.sockPath, { kind: 'health_pulse' })
    const n = await handle.waitFor(x => x.params.meta.kind === 'health_pulse')
    expect(n.params.content).toBe(
      'Lifecycle: ping. Reply with a short status to confirm responsiveness.',
    )
    expect(Object.keys(n.params.meta).sort()).toEqual(['kind', 'ts'])
  })

  test('external_event interpolates source and body with source folded into meta', async () => {
    await sendLine(handle.sockPath, {
      kind: 'external_event',
      source: 'ci',
      body: 'deploy-prod #159 succeeded',
    })
    const n = await handle.waitFor(x => x.params.meta.kind === 'external_event')
    expect(n.params.content).toBe(
      'Lifecycle: external event from ci — deploy-prod #159 succeeded',
    )
    expect(n.params.meta.source).toBe('ci')
    expect(n.params.meta.kind).toBe('external_event')
  })
})
