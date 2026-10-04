// Runs corpus cases against a target (oracle or emulator) in isolation,
// ported from msduck runCase + isolatedReference.
//
// Isolation modes:
//   database  CREATE DATABASE [bitsql_case_<random>] on an admin connection,
//             run the case connected to it, DROP it afterwards (oracle default,
//             and the emulator default with BITSQL_ADDR).
//   process   spawn a fresh emulator process per case, CREATE DATABASE in it
//             and run there (default when the harness spawns the emulator
//             itself). The case database is never master: SQL Server's
//             captures ran in a user database, and master differs (recovery
//             model, system objects, the name itself).
// Database names inside strings become `{db}` so both modes compare equal.
import { randomBytes } from 'node:crypto'
import { capture, canonical, normalizeSpids, replaceDatabaseName } from './capture-core.mjs'
import { caseHash } from './corpus.mjs'
import { connect, close, withDatabase } from './client.mjs'
import { startOracle } from './oracle.mjs'
import { emulatorBinary, emulatorConfig, fixedAddress, probe, spawnEmulator } from './emulator.mjs'

export const REUSE_PROBE = 'SELECT @@TRANCOUNT AS trancount, XACT_STATE() AS xact_state; SELECT 1 AS reusable'

export async function oracleTarget({ log, name, port } = {}) {
  const { config, image } = await startOracle({ log, name, port })
  const admin = await connect(config)
  const version = (await capture(admin, { kind: 'batch', sql: "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))" })).sets[0].rows[0][0]
  await close(admin)
  return { name: 'oracle', server: { image, version }, isolation: 'database', session: async () => ({ config, dispose: async () => {} }) }
}

export async function emulatorTarget({ isolation, log } = {}) {
  const fixed = fixedAddress()
  if (fixed) {
    const error = await probe(fixed)
    if (error) throw error
    return { name: 'emulator', server: { addr: process.env.BITSQL_ADDR }, isolation: isolation ?? 'database', session: async () => ({ config: emulatorConfig(fixed), dispose: async () => {} }) }
  }
  const bin = emulatorBinary({ log })
  // One probe server: fail fast with "server not available".
  const first = await spawnEmulator({ bin })
  const error = await probe(first)
  if (error) { await first.stop(); throw error }
  const mode = isolation ?? 'process'
  if (mode === 'database') {
    return { name: 'emulator', server: { bin }, isolation: mode, session: async () => ({ config: emulatorConfig(first), dispose: async () => {} }), stop: first.stop }
  }
  await first.stop()
  return {
    name: 'emulator', server: { bin }, isolation: mode,
    session: async () => { const s = await spawnEmulator({ bin }); return { config: emulatorConfig(s), dispose: s.stop } },
  }
}

// `-- @mask a/*/b` paths: the values there become "{masked}".
export function applyMasks(result, masks) {
  if (!masks?.length) return result
  const walk = (node, parts) => {
    if (node === null || typeof node !== 'object') return
    const [head, ...rest] = parts
    const keys = head === '*' ? Object.keys(node) : [head]
    for (const k of keys) {
      if (!(k in node)) continue
      if (rest.length) walk(node[k], rest)
      else node[k] = '{masked}'
    }
  }
  for (const m of masks) walk(result, m.split('/'))
  return result
}

// Time an async step gets to reach the server and start (and block) before
// the next step is sent.
const ASYNC_SETTLE_MS = 500

async function runSteps(config, steps) {
  const result = { steps: [] }
  const connections = new Map()
  const pending = new Map() // conn → { index, promise }
  const conn = async id => {
    if (!connections.has(id)) connections.set(id, await connect(config))
    return connections.get(id)
  }
  const settle = async id => {
    const p = pending.get(id)
    if (!p) return
    pending.delete(id)
    result.steps[p.index] = await p.promise
  }
  try { await conn(1) }
  catch (error) { return { connectError: error.message } }
  try {
    for (const step of steps) {
      const id = step.conn ?? 1
      const index = result.steps.length
      if (step.kind === 'await') { result.steps.push(null); await settle(id); continue }
      await settle(id)
      const connection = await conn(id)
      if (step.async) {
        result.steps.push(null)
        pending.set(id, { index, promise: capture(connection, step).then(r => applyMasks(r, step.mask)) })
        await new Promise(resolve => setTimeout(resolve, ASYNC_SETTLE_MS))
      } else {
        result.steps.push(applyMasks(await capture(connection, step), step.mask))
      }
    }
    for (const id of [...pending.keys()]) await settle(id)
    result.reuse = await capture(await conn(1), { kind: 'batch', sql: REUSE_PROBE })
  } finally { for (const c of connections.values()) await close(c) }
  return result
}

export async function runCase(target, testCase) {
  const session = await target.session()
  let database = 'master'
  let admin
  try {
    let config = session.config
    if (target.isolation === 'database' || target.isolation === 'process') {
      admin = await connect(config)
      database = `bitsql_case_${randomBytes(6).toString('hex')}`
      const created = await capture(admin, { kind: 'batch', sql: `CREATE DATABASE [${database}]` })
      if (created.errors.length) return { case: caseHash(testCase.steps), isolationError: created.errors[0].message }
      config = withDatabase(config, database)
    }
    const raw = await runSteps(config, testCase.steps)
    const result = normalizeSpids(replaceDatabaseName(canonical(raw), database))
    return { case: caseHash(testCase.steps), ...result }
  } catch (error) {
    return { case: caseHash(testCase.steps), transportError: error.message }
  } finally {
    if (admin) {
      if (database !== 'master' && target.isolation === 'database') {
        // Only the freshly generated database is dropped; kick lingering sessions first.
        await capture(admin, { kind: 'batch', sql: `IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}] END` })
      }
      await close(admin)
    }
    await session.dispose()
  }
}

// Turns a run result into the stored expectation: setup steps (compare:false)
// become null; client-side failures make the capture unusable.
export function toExpected(testCase, result) {
  if (result.connectError || result.transportError || result.isolationError) return { error: result.connectError ?? result.transportError ?? result.isolationError }
  const clientError = [...result.steps, result.reuse].flatMap(s => s?.errors ?? []).find(e => e.client)
  if (clientError) return { error: `client-side error: ${clientError.message}` }
  return {
    expected: {
      case: result.case,
      steps: result.steps.map((s, i) => testCase.steps[i].compare === false ? null : s),
      reuse: result.reuse,
    },
  }
}

export async function pool(items, concurrency, work) {
  const results = new Array(items.length)
  let next = 0
  const workers = Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, async () => {
    while (next < items.length) { const i = next++; results[i] = await work(items[i], i) }
  })
  await Promise.all(workers)
  return results
}
