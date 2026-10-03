// msduck layout adapters: runs2 group (see project.mjs for the Run/Entry shape).
// Keys are msduck reference file base names; values (doc, ctx) => Run[].
//
// Files here are `runs: [[{name, sql|query, result, mode?, ...}]]` (runs[0]
// and runs[1] are identical captures from two containers; runs[0] is used)
// or `runs: [{batches, prepared}]`. All were captured sequentially on one
// connection, but almost every entry is a self-contained query. Each entry
// becomes an independent case whose setup replays only the earlier entries
// that can change state (DDL/DML/SET/EXEC/transactions...), so a case never
// pays for hundreds of unrelated SELECTs yet still sees the tables and rows
// the capture saw.
//
// Results: the msduck lib capture {sets, done, errors, info, returnStatus,
// rowCount} plus, in token-observing scripts (capture-order-token.mjs
// captureBatch/captureRpc), `returnValues` (-> outputs), `doneTokens`
// (-> tokens) and `events` (one per token, -> bitsql `stream` with ROW runs
// expanded). Dropped as unobservable in bitsql captures: column/returnValue
// `userType`, returnValue flags/collation, raw DONE `status`/`rawDone`
// (carries DONE_INXACT, which tedious does not expose), ORDER raw hex.
// `bits` (float wire bit patterns) only restores -0, which JSON rows lose.
import { scrub, STANDARD_KEYS, projectLike, tediousParam } from './project.mjs'

const VERSION_PROBE = /SERVERPROPERTY\s*\(\s*'ProductVersion'\s*\)/i
const STATEFUL = /\b(INTO|INSERT|UPDATE|DELETE|MERGE|CREATE|DROP|ALTER|TRUNCATE|EXEC|EXECUTE|TRAN|TRANSACTION|COMMIT|ROLLBACK|SAVE|USE|GRANT|DENY|REVOKE|DBCC|RETURN)\b|\bSET\s+(?!@)/i
const readOnly = sql => /^\s*(WITH|SELECT|DECLARE)\b/i.test(sql) && !STATEFUL.test(sql)
const isMissing = v => v === undefined || (v && typeof v === 'object' && v.kind === 'missing')

function utf16Decode(hex) {
  let s = ''
  for (let i = 0; i + 3 < hex.length; i += 4) s += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16) | (parseInt(hex.slice(i + 2, i + 4), 16) << 8))
  return s
}

// Expected value side: msduck values -> bitsql canonical values.
function fixRows(sets, bits) {
  return sets.map((set, si) => ({
    ...set,
    columns: set.columns.map(({ userType, ...c }) => c),
    ...(set.rows ? {
      rows: set.rows.map((row, ri) => row.map((v, ci) => {
        if (v && typeof v === 'object' && v.kind === 'utf16') return utf16Decode(v.value)
        if (v === 0 && ['80000000', '8000000000000000'].includes(bits?.[si]?.[ri]?.[ci])) return { kind: 'number', value: '-0' }
        return v
      })),
    } : {}),
  }))
}

const tokenOf = t => ({ name: t.name ?? t.kind, more: t.more, sqlError: t.sqlError, attention: t.attention, serverError: t.serverError, rowCount: isMissing(t.rowCount) ? null : t.rowCount, curCmd: t.curCmd ?? t.command })
function eventsOf(stream) {
  const out = []
  for (const e of stream ?? []) {
    if (e.name === 'ROW' || e.name === 'NBCROW') for (let i = 0; i < e.count; i++) out.push({ kind: e.name })
    else if (e.name === 'ORDER') out.push({ kind: 'ORDER', ordinals: e.columns })
    else out.push({ kind: e.name })
  }
  return out
}

// msduck result (lib or token-observing capture) -> Expect.
export function richExpect(raw, { bits } = {}) {
  const r = scrub(raw)
  const value = {}
  for (const k of STANDARD_KEYS) {
    if (!(k in r)) continue
    value[k] = (k === 'returnStatus' || k === 'rowCount') && isMissing(r[k]) ? null : r[k]
  }
  if (value.sets) value.sets = fixRows(value.sets, bits)
  if (Array.isArray(r.returnValues)) value.outputs = r.returnValues.map(v => ({ name: v.name, type: v.type, length: v.length ?? null, precision: v.precision ?? null, scale: v.scale ?? null, value: v.value }))
  if (Array.isArray(r.doneTokens)) value.tokens = r.doneTokens.map(tokenOf)
  if (Array.isArray(r.events)) value.events = r.events.map(e => e.kind === 'ORDER' && e.ordinals ? { kind: 'ORDER', ordinals: e.ordinals } : { kind: e.kind })
  return {
    value,
    project: actual => {
      const a = {}
      for (const k of Object.keys(value)) {
        if (k === 'tokens') a.tokens = (actual.tokens ?? []).map(tokenOf)
        else if (k === 'events') a.events = eventsOf(actual.stream)
        else if (k === 'outputs') a.outputs = (actual.outputs ?? []).map(o => ({ ...o, name: String(o.name).replace(/^@/, '') }))
        else a[k] = (k === 'returnStatus' || k === 'rowCount') && isMissing(actual[k]) ? null : actual[k]
      }
      // Without `bits` msduck's JSON rows cannot tell -0 from 0; compare
      // sign-insensitively (the stored expectation keeps the oracle's -0).
      if (!bits && a.sets) a.sets = a.sets.map(s => s.rows ? { ...s, rows: s.rows.map(r => r.map(v => v?.kind === 'number' && v.value === '-0' ? 0 : v)) } : s)
      return projectLike(a, value)
    },
  }
}

// items: [{ name, steps: [{kind, sql, params?, expect?}], skip?, readOnly? }]
// -> one independent run; non-read-only items replay as setup of later ones.
function chain(id, items) {
  const state = []
  const entries = []
  for (const it of items) {
    if (it.skip) { entries.push({ name: it.name, skip: it.skip, stateless: true }); continue }
    entries.push({ name: it.name, steps: [...state.map(s => ({ ...s })), ...it.steps] })
    const ro = it.readOnly ?? it.steps.every(s => s.kind !== 'proc' && readOnly(s.sql))
    if (!ro) state.push(...it.steps.map(({ expect, ...s }) => s))
  }
  return [{ id, independent: true, entries }]
}

// Generic `runs: [[entry]]` adapter. `params(entry)` returns undefined for a
// batch entry or an array of corpus params for an RPC (execSql) entry;
// `extra(entry)` returns additional compared steps run after the entry.
function runsAdapter({ params = () => undefined, rpc = () => false, skip = () => null, extra = () => [] } = {}) {
  return doc => {
    const run = Array.isArray(doc.runs[0]) ? doc.runs[0] : doc.runs
    const items = run.map(e => {
      const sql = e.sql ?? e.query
      const reason = skip(e)
      if (reason) return { name: e.name, skip: reason }
      if (typeof sql !== 'string') return { name: e.name, skip: 'no SQL recorded' }
      if (VERSION_PROBE.test(sql)) return { name: e.name, skip: 'server version probe' }
      const p = params(e)
      const kind = p !== undefined || rpc(e) ? 'rpc' : 'batch'
      const step = { kind, sql, ...(p?.length ? { params: p } : {}), expect: richExpect(e.result, { bits: e.bits }) }
      return { name: e.name, steps: [step, ...extra(e)] }
    })
    return chain('run', items)
  }
}

const preparedSkip = e => e.mode === 'prepared' ? 'prepared protocol (sp_prepare/sp_execute)' : null
const one = (name, type) => e => 'parameter' in e ? [{ name, type, value: e.parameter }] : undefined

// `runs: [{batches: [{name, sql, result}], prepared: {sql, runs: [...]}}]`
const batchesAdapter = doc => {
  const r = doc.runs[0]
  const items = r.batches.map(b => VERSION_PROBE.test(b.sql)
    ? { name: b.name, skip: 'server version probe' }
    : { name: b.name, steps: [{ kind: 'batch', sql: b.sql, expect: richExpect(b.result) }] })
  for (const [i] of (r.prepared?.runs ?? []).entries()) items.push({ name: `prepared ${i}`, skip: 'prepared protocol (sp_prepare/sp_execute)' })
  return chain('run', items)
}

const plain = runsAdapter()
const modeRpc = runsAdapter({ rpc: e => e.mode === 'rpc', skip: preparedSkip })

export default {
  'char-byte': runsAdapter({ params: one('n', 'int') }),
  // reset (DELETE + reseed rows) runs before every query, followup after it.
  'count-null-compilation': doc => {
    const run = doc.runs[0]
    const items = run.map(e => {
      if (VERSION_PROBE.test(e.sql)) return { name: e.name, skip: 'server version probe' }
      const main = { kind: e.mode === 'rpc' ? 'rpc' : 'batch', sql: e.sql, expect: richExpect(e.result) }
      if (!e.reset) return { name: e.name, steps: [main] }
      return {
        name: `${e.name} ${e.mode}`, readOnly: true, // reset restores the table each time
        steps: [{ kind: 'batch', sql: e.reset.sql }, main, { kind: 'batch', sql: e.followup.sql, expect: richExpect(e.followup.result) }],
      }
    })
    return chain('run', items)
  },
  'count-ranking-declarations': runsAdapter({ rpc: e => e.mode === 'rpc' }),
  'datepart-numeric': runsAdapter({ params: e => e.parameters?.map(p => tediousParam([p.name, p.type, p.value, p.options])) }),
  'distribution-reference': plain,
  'float-aggregates': plain,
  'for-xml-path': plain,
  'guid-assignment': runsAdapter({ params: e => e.parameter ? [tediousParam(['g', e.parameter.type, e.parameter.value, e.parameter.length ? { length: e.parameter.length } : undefined])] : undefined }),
  'guid-character-conversion': runsAdapter({ extra: e => e.recovery ? [{ kind: 'batch', sql: 'SELECT 1 AS reusable', expect: richExpect(e.recovery) }] : [] }),
  'guid-conversion-order': plain,
  'ntile-null': runsAdapter({ params: e => e.mode === 'rpc' ? [{ name: 'b', type: 'int', value: e.parameter }] : undefined }),
  'ntile-types': modeRpc,
  'numeric-arithmetic-context': batchesAdapter,
  'numeric-literal-metadata': batchesAdapter,
  'percentile-character-fraction': modeRpc,
  // Same SQL as -v2 (a later recapture); importing both would duplicate 212 cases.
  'percentile-numeric-rounding': (doc, { skip }) => { skip('superseded by percentile-numeric-rounding-v2 (same SQL)', doc.runs[0].length); return [] },
  'percentile-numeric-rounding-v2': plain,
  'percentile-order-type': modeRpc,
  'percentile-reference': modeRpc,
  'percentile-runtime-fraction': modeRpc,
  quotename: plain,
  'select-top-percent': runsAdapter({
    skip: e => /^prepared /.test(e.name) ? 'prepared protocol (sp_prepare/sp_execute)' : null,
    params: e => e.name === 'RPC percent first' ? [{ name: 'p', type: 'float', value: 25 }] : e.name === 'RPC percent null' ? [{ name: 'p', type: 'float', value: null }] : undefined,
  }),
  'statistical-aggregates': plain,
  'statistical-precision': plain,
  'statistical-transition': plain,
  'string-escape-format': runsAdapter({ params: e => e.parameter ? [tediousParam(['f', e.parameter.type, e.parameter.value])] : undefined }),
}
