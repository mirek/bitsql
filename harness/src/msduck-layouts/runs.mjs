// msduck layout adapters: `runs: [[{name, sql, result, ...}]]` sequential
// captures (identity-insert*, merge-*, order-token*, session-*, catalog
// probes, ...). runs[0] is used; msduck's second run is a repeat on a fresh
// database/container. See project.mjs for the Run/Entry shape.
//
// Result shapes met here:
//   standard  {sets, done, errors, info, returnStatus, rowCount}
//   rich      standard + doneTokens [{kind, more, sqlError, attention,
//             serverError, rowCount|null, command, status}] + events [{kind}]
//             (every token tedious parsed; ORDER adds ordinals) + returnValues;
//             column descriptors carry `userType` (not captured by bitsql)
//   raw done  tedious-compat-gaps, alter-database-sessions: done [{kind, status, curCmd, rowCount: "<u64>"}]
import { doneKind, doneStatus, projectLike, scrub, standardExpect, STANDARD_KEYS, tediousParam } from './project.mjs'

const isMissing = v => v === undefined || v === null || (v && typeof v === 'object' && v.kind === 'missing')

// DONE tokens in msduck's decoded layout, from bitsql's `tokens`.
const doneTokensOf = actual => (actual.tokens ?? []).map(t => ({
  kind: t.name, more: t.more, sqlError: t.sqlError, attention: t.attention, serverError: t.serverError,
  rowCount: (doneStatus(t) & 0x10) ? t.rowCount : null, command: t.curCmd, status: doneStatus(t),
}))
// Token names in arrival order (ROW runs expanded), from bitsql's `stream`.
const eventsOf = actual => (actual.stream ?? []).flatMap(e => {
  if (e.name === 'ROW' || e.name === 'NBCROW') return Array(e.count).fill({ kind: e.name })
  if (e.name === 'ORDER') return [{ kind: 'ORDER', ordinals: e.columns }]
  return [{ kind: e.name }]
})
const outputsOf = actual => (actual.outputs ?? []).map(o => ({ name: o.name, value: o.value, type: o.type, length: o.length, precision: o.precision, scale: o.scale }))

// Drops what bitsql's capture cannot observe (userType, ORDER hex/length,
// return-value flags/collation) from a msduck result.
function cleanRich(result) {
  const r = scrub(result)
  for (const set of r.sets ?? []) for (const c of set.columns ?? []) delete c.userType
  // rand-session records floats as {value, floatBits}; the JS number is exact.
  for (const set of r.sets ?? []) if (set.rows) set.rows = set.rows.map(row => row.map(v => v && typeof v === 'object' && 'floatBits' in v ? v.value : v))
  for (const e of r.events ?? []) { delete e.hex; delete e.length }
  for (const v of r.returnValues ?? []) { delete v.userType; delete v.flags; delete v.collation }
  return r
}

// standard + doneTokens/events/returnValues when recorded.
export function richExpect(result) {
  const r = cleanRich(result)
  const extra = ['doneTokens', 'events', 'returnValues'].filter(k => k in r)
  const base = standardExpect(r)
  const value = { ...base.value }
  for (const k of extra) value[k] = r[k]
  return {
    value,
    project: actual => {
      const out = base.project(actual)
      if (extra.includes('doneTokens')) out.doneTokens = projectLike(doneTokensOf(actual), r.doneTokens)
      if (extra.includes('events')) out.events = projectLike(eventsOf(actual), r.events)
      if (extra.includes('returnValues')) out.returnValues = projectLike(outputsOf(actual), r.returnValues)
      return out
    },
  }
}

// tedious-compat-gaps: done words recorded raw from the TDS stream.
function rawDoneExpect(result) {
  const r = scrub(result)
  const keys = STANDARD_KEYS.filter(k => k in r && k !== 'done')
  const base = standardExpect(r, { keys })
  return {
    value: { ...base.value, done: r.done },
    project: actual => ({
      ...base.project(actual),
      done: projectLike((actual.tokens ?? []).map(t => ({ kind: doneKind(t.name), status: doneStatus(t), curCmd: t.curCmd, rowCount: String(isMissing(t.rowCount) ? 0 : t.rowCount) })), r.done),
    }),
  }
}

const batch = (sql, result, expectFn = richExpect) => [{ kind: 'batch', sql, expect: expectFn(result) }]
const isRead = sql => /^\s*select\b/i.test(sql) && !/\binto\b/i.test(sql)

// Generic: every entry a batch on one connection.
const sequential = (expectFn = richExpect) => doc => [{
  id: 'run',
  entries: doc.runs[0].map(e => e.sql === undefined || e.result == null
    ? { name: e.name, skip: 'no SQL request recorded' }
    : { name: e.name, steps: batch(e.sql, e.result, expectFn) }),
}]

// Entries naming a second connection: reads there do not change the first
// session's state (stateless skip); writes do.
function secondSession(e, primary) {
  if (e.session === undefined || e.session === primary) return null
  return { name: e.name, skip: 'multi-connection (second session)', ...(isRead(e.sql ?? '') ? { stateless: true } : {}) }
}

const intParams = parameters => Object.entries(parameters ?? {}).map(([name, value]) => ({ name, type: 'int', value }))

const adapters = {
  'identity-insert': doc => [{
    id: 'run',
    entries: doc.runs[0].map(e => secondSession(e, 'A') ?? { name: e.name, steps: batch(e.sql, e.result) }),
  }],
  'identity-insert-column-order': sequential(),
  'identity-insert-conversion': sequential(),
  'identity-insert-errors': sequential(),
  'identity-insert-multirow': sequential(),
  'identity-insert-name-errors': sequential(),
  'identity-insert-shapes': sequential(),
  // mode rpc: tedious execSql with Int parameters { name: value }.
  // The prepared block (sp_prepare/sp_execute) poisons the rest of the alpha
  // run; the descending_ids section after it only needs that table's
  // creation and baseline row, so it restarts as its own run with those two
  // statements replayed as setup.
  'identity-insert-rpc': doc => {
    const toEntry = e => {
      if (e.mode === 'prepared') return { name: e.name, skip: 'prepared protocol (sp_prepare/sp_execute)' }
      if (e.mode === 'rpc') return { name: e.name, steps: [{ kind: 'rpc', sql: e.sql, params: intParams(e.parameters), expect: richExpect(e.result) }] }
      return { name: e.name, steps: batch(e.sql, e.result) }
    }
    const entries = doc.runs[0]
    const cut = entries.findIndex(e => e.name === 'descending ON')
    const setup = entries.filter(e => ['create descending', 'baseline descending'].includes(e.name)).map(e => ({ name: `${e.name} (setup)`, steps: [{ kind: 'batch', sql: e.sql }] }))
    return [{ id: 'alpha', entries: entries.slice(0, cut).map(toEntry) }, { id: 'descending', entries: [...setup, ...entries.slice(cut).map(toEntry)] }]
  },
  'identity-retrieval': doc => [{
    id: 'run',
    entries: doc.runs[0].map(e => secondSession(e, 'primary') ?? (e.parameters
      ? { name: e.name, steps: [{ kind: 'rpc', sql: e.sql, params: intParams(e.parameters), expect: standardExpect(e.result) }] }
      : { name: e.name, steps: batch(e.sql, e.result, standardExpect) })),
  }],

  'merge-execution': sequential(standardExpect),
  'merge-top': sequential(standardExpect),
  'merge-top-percent': sequential(standardExpect),
  // Seven independent scenarios (own tables, each ends with no open
  // transaction): one run per scenario. msduck read each scenario's tables
  // again from a new connection at the end (`after reconnect`, recorded with
  // placeholder SQL); with no transaction open the same read on the owning
  // connection observes the same committed state, so it ends its scenario.
  'merge-transaction': doc => {
    const runs = new Map()
    const head = { id: 'session', entries: [] }
    for (const e of doc.runs[0]) {
      const m = /^(.*?): (.*)$/.exec(e.name)
      if (!m) { head.entries.push({ name: e.name, steps: batch(e.sql, e.result, standardExpect) }); continue }
      const [, scenario, what] = m
      if (!runs.has(scenario)) runs.set(scenario, { id: scenario.replace(/\s+/g, '-'), entries: [] })
      let sql = e.sql
      if (what === 'after reconnect') {
        const table = /FROM dbo\.(\w+)$/.exec(e.sql)?.[1]
        if (!table) { runs.get(scenario).entries.push({ name: e.name, skip: 'placeholder SQL' }); continue }
        sql = `SELECT id,n FROM dbo.${table} ORDER BY id; SELECT id,n FROM dbo.${table}_prior ORDER BY id; SELECT [action],inserted_id FROM dbo.${table}_sink ORDER BY [action],inserted_id;`
      }
      runs.get(scenario).entries.push({ name: e.name, steps: batch(sql, e.result, standardExpect) })
    }
    return [{ ...head, independent: true }, ...runs.values()]
  },

  // setup, then each query as a batch and as an RPC; prepared entries skipped
  // (they come last).
  'order-token': doc => [{ id: 'run', entries: doc.runs[0].map(orderEntry) }],
  'order-token-expanded': doc => [{ id: 'run', entries: doc.runs[0].map(orderEntry) }],

  // Entries without SQL are tedious connection.reset() (RESETCONNECTION) or
  // prepared-handle phases.
  'session-reset': sequential(standardExpect),

  // rpc: execSql (sp_executesql) with [{name, type: tedious name, value}].
  'session-property-context': doc => [{
    id: 'run',
    entries: doc.runs[0].map(e => {
      if (e.sql === undefined) return { name: e.name, skip: 'session reset (resetConnection)' }
      const params = (e.parameters ?? []).map(p => tediousParam([p.name, p.type, p.value]))
      // done[].status (the DONEPROC return status, also in returnStatus) and
      // errors[].procName are not in bitsql captures.
      const result = structuredClone(e.result)
      for (const d of result.done ?? []) delete d.status
      for (const m of [...(result.errors ?? []), ...(result.info ?? [])]) delete m.procName
      return { name: e.name, steps: [{ kind: e.rpc ? 'rpc' : 'batch', sql: e.sql, ...(params.length ? { params } : {}), expect: standardExpect(result) }] }
    }),
  }],

  // Connection `a` (master) probes, then DDL/DML on connection `db` inside a
  // fixed-name database probe_db (here: the case database). Server-level
  // objects with fixed names (probe_db, probe_login), the probe login's own
  // connection and the multi-session ALTER DATABASE section are skipped.
  'tedious-compat-gaps': doc => {
    const entries = doc.runs[0]
    const at = name => entries.findIndex(e => e.name === name)
    const created = at('create probe database'), dbStart = at('computed repro table'), dbEnd = at('hint in transaction')
    const toEntry = e => e.result?.waited !== undefined
      ? { name: e.name, skip: 'cancelled after a wait bound (attention)' }
      : { name: e.name, steps: batch(e.sql, e.result, rawDoneExpect) }
    const master = { id: 'master', entries: entries.slice(0, created).map(toEntry) }
    const db = { id: 'db', entries: entries.slice(dbStart, dbEnd + 1).map(toEntry) }
    const rest = [...entries.slice(created, dbStart), ...entries.slice(dbEnd + 1)]
    return [master, db, { id: 'rest', entries: rest.map(e => ({ name: e.name, skip: 'fixed-name server objects (probe_db/probe_login) or multi-connection', stateless: true })) }]
  },

  'sys-databases': sequential(standardExpect),
  // batch and RPC forms; the last three bind @p int.
  'quoted-session-identifiers': doc => [{
    id: 'run',
    entries: doc.runs[0].map(e => ({
      name: `${e.name} ${e.mode}`,
      steps: [{
        kind: e.mode === 'rpc' ? 'rpc' : 'batch', sql: e.sql,
        ...(e.parameter ? { params: [tediousParam([e.parameter.name, e.parameter.type, e.parameter.value])] } : {}),
        expect: richExpect(e.result),
      }],
    })),
  }],
  'rand-session': doc => [{
    id: 'run',
    entries: doc.runs[0].map(e => e.mode === 'prepared'
      ? { name: e.name, skip: 'prepared protocol (sp_prepare/sp_execute)' }
      : secondSession(e, 'primary') ?? { name: e.name, steps: batch(e.sql, e.result) }),
  }],

  // Connection `a` in master; everything from CREATE DATABASE [probe_db] on
  // uses a fixed-name server database and up to four sessions.
  'alter-database-sessions': doc => {
    const entries = doc.runs[0]
    const cut = entries.findIndex(e => e.name === 'create probe')
    return [{
      id: 'run',
      entries: entries.map((e, i) => i >= cut
        ? { name: e.name, skip: 'fixed-name server database (probe_db) / multi-connection', stateless: true }
        : { name: e.name, steps: batch(e.sql, e.result, rawDoneExpect) }),
    }]
  },
  'alter-named-default': sequential(standardExpect),
  // `observer ...` entries ran on a second connection (reads only).
  'all-objects': doc => [{
    id: 'run',
    entries: doc.runs[0].map(e => /observer/.test(e.name)
      ? { name: e.name, skip: 'multi-connection (observer session)', stateless: true }
      : { name: e.name, steps: batch(e.sql, e.result, standardExpect) }),
  }],
  // `fresh full catalog` dumps all 12.8k system columns (4 MB): read-only,
  // skipped for size.
  'system-all-columns': doc => sequential(standardExpect)(doc).map(run => ({
    ...run,
    entries: run.entries.map(e => e.name === 'fresh full catalog' ? { name: e.name, skip: 'full system catalog dump (4 MB)', stateless: true } : e),
  })),
  // { runs: [{ setup, rejected, observations, collation }] } in that order.
  'table-type-catalog': doc => {
    const r = doc.runs[0]
    const list = [
      ...r.setup.map((e, i) => ({ name: `setup ${i}`, ...e })),
      ...r.rejected.map((e, i) => ({ name: `rejected ${i}`, ...e })),
      ...r.observations,
      ...r.collation.map((e, i) => ({ name: `collation ${i}`, ...e })),
    ]
    return [{ id: 'run', entries: list.map(e => ({ name: e.name, steps: batch(e.sql, e.result, standardExpect) })) }]
  },
}

// Server version probes differ by build (msduck 17.0.4065.4, local
// 17.0.5005.3) and change no state: skip them up front.
const versionProbe = /SERVERPROPERTY\('ProductVersion'\)/i
export default Object.fromEntries(Object.entries(adapters).map(([name, adapt]) => [name, async (doc, ctx) => {
  const runs = await adapt(doc, ctx)
  for (const run of runs) {
    run.entries = run.entries.map(e => e.steps?.length === 1 && versionProbe.test(e.steps[0].sql) ? { name: e.name, skip: 'server version probe', stateless: true } : e)
  }
  return runs
}]))

function orderEntry(e) {
  if (e.mode === 'prepared') return { name: `${e.name} prepared`, skip: 'prepared protocol (sp_prepare/sp_execute)' }
  return { name: `${e.name} ${e.mode}`, steps: [{ kind: e.mode === 'rpc' ? 'rpc' : 'batch', sql: e.sql, expect: richExpect(e.result) }] }
}

