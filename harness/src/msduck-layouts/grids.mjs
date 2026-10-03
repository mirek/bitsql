// msduck layout adapters: function grids in the `containers: [{image, runs}]`
// layout (see project.mjs for the Run/Entry shape).
//
// Every file was captured by one script with isolatedReference(): one fresh
// database, one connection, records in order. Records are
//   { name, sql, result }                       SQL batch
//   { name, sql, parameters, result }           sp_executesql (tedious execSql)
//   { ..., prepared | declarations | executions } sp_prepare/sp_execute (skipped)
// with per-file extras (concat-*: `reuse` probe batch after each case;
// cursor: `session`, `kind`, raw DONE tokens; isjson-depth: generated @j;
// like-patterns/offset-functions: `{records, prepared}`). containers[0].runs[0]
// is used (msduck verified all containers/runs identical).
//
// Most records are independent SELECTs over a few setup tables, so a grid
// becomes one independent run whose every case first replays the earlier
// state-changing records (CREATE/INSERT/SET/...) as uncompared setup, and then
// its own request. Small truly sequential files (cursor, rowversion,
// table-variable) stay sequential runs. Large grids are sampled
// deterministically (stride, always keeping errors and new result shapes).
import { createHash } from 'node:crypto'
import { customExpect, doneKind, doneStatus, standardExpect, tediousParam } from './project.mjs'

const COLUMN_KEYS = ['name', 'type', 'length', 'precision', 'scale', 'flags', 'collation']
// Keeps the column fields bitsql captures and drops message fields it does
// not record (serverName, procName from some scripts' errorFields).
const MESSAGE_KEYS = ['number', 'state', 'class', 'lineNumber', 'message']
const cleanMessages = list => list?.map(m => Object.fromEntries(MESSAGE_KEYS.filter(k => k in m).map(k => [k, m[k]])))
const cleanColumns = result => {
  if (!result || typeof result !== 'object') return result
  const out = { ...result }
  if (result.sets) out.sets = result.sets.map(set => ({ ...set, columns: set.columns.map(c => Object.fromEntries(COLUMN_KEYS.filter(k => k in c).map(k => [k, c[k]]))) }))
  if (result.errors) out.errors = cleanMessages(result.errors)
  if (result.info) out.info = cleanMessages(result.info)
  return out
}
// compress-decompress replaced values longer than 256 bytes/units by a
// digest (capture script boundValue); the same is applied to bitsql's rows.
function boundValue(value) {
  if (value && value.kind === 'binary' && value.value.length / 2 > 256) {
    const b = Buffer.from(value.value, 'hex')
    return { kind: 'digest', type: 'binary', length: b.length, sha256: createHash('sha256').update(b).digest('hex'), head: b.subarray(0, 16).toString('hex') }
  }
  if (typeof value === 'string' && value.length > 256) {
    return { kind: 'digest', type: 'string', length: value.length, sha256Utf16le: createHash('sha256').update(Buffer.from(value, 'utf16le')).digest('hex'), head: value.slice(0, 16) }
  }
  return value
}
const hasDigest = result => JSON.stringify(result?.sets ?? []).includes('"kind":"digest"')
const boundRows = picked => picked.sets ? { ...picked, sets: picked.sets.map(set => ({ ...set, rows: set.rows?.map(row => row.map(boundValue)) })) } : picked
const expectOf = result => standardExpect(cleanColumns(result), hasDigest(result) ? { transform: boundRows } : {})

const VERSION_PROBE = /SERVERPROPERTY\('Product(Major)?Version'\)/i
const STATEFUL = /\b(CREATE|INSERT|UPDATE|DELETE|ALTER|DROP|TRUNCATE|MERGE|USE|EXEC(UTE)?|BEGIN\s+TRAN(SACTION)?|COMMIT|ROLLBACK|SAVE|DBCC|OPEN|CLOSE|DEALLOCATE)\b|\bSET\s+(?!@)[A-Z_]/i
const stripComments = sql => sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ')
const stateful = sql => STATEFUL.test(stripComments(sql))

// msduck parameter records {name, type, value, options?} -> corpus params, or
// null when the value cannot be bound from JSON (digests, NaN/Infinity/-0).
function paramsOf(parameters) {
  const out = []
  for (const p of parameters) {
    const [name, type, value, options] = Array.isArray(p) ? p : [p.name, p.type, p.value, p.options]
    if (value === undefined) return null
    if (value && typeof value === 'object' && !['binary', 'bigint', 'date'].includes(value.kind)) return null
    const param = tediousParam([name, type, value, options])
    if (String(type).toLowerCase() === 'time' && typeof param.value === 'string' && param.value.includes('T')) param.value = param.value.slice(11).replace(/Z$/, '')
    out.push(param)
  }
  return out
}

const isPrepared = e => e.prepared !== undefined || e.executions !== undefined || e.declarations !== undefined || e.protocol?.startsWith('sp_prepare') || e.kind === 'prepared' || e.mode === 'prepared'

// One record -> { name, steps } or { name, skip } (without setup replay).
function entryOf(e, { name = e.name, rpcParams } = {}) {
  if (isPrepared(e)) return { name, skip: 'prepared protocol (sp_prepare/sp_execute)', stateless: true }
  if (!e.result) return { name, skip: 'no result recorded', stateless: true }
  if (e.result.truncated) return { name, skip: 'bounded capture overflowed', stateless: true }
  if (VERSION_PROBE.test(e.sql ?? '')) return { name, skip: 'server version probe', stateless: true }
  const step = { kind: 'batch', sql: e.sql, expect: expectOf(e.result) }
  const parameters = rpcParams ?? e.parameters ?? e.params
  if (parameters) {
    const params = Array.isArray(parameters) ? paramsOf(parameters) : Object.entries(parameters).map(([n, v]) => ({ name: n, type: 'int', value: v }))
    if (!params) return { name, skip: 'parameter value not representable (digest or non-finite)', stateless: true }
    step.kind = 'rpc'
    if (params.length) step.params = params
  }
  const steps = [step]
  if (e.reuse) steps.push({ kind: 'batch', sql: 'SELECT @@TRANCOUNT AS transaction_count,1 AS reusable', expect: expectOf(e.reuse) })
  return { name, steps }
}

// Deterministic sample to about `target` bytes of corpus output (estimated
// from the cleaned msduck result plus the replayed setup): stateful records
// are always kept, records with a new (error numbers, column types)
// signature while they fit a third of the budget, the rest by a stable
// name-hash stride.
const clean = r => r ? JSON.stringify(cleanColumns({ ...r, tokens: undefined, events: undefined })).length : 0
function sample(records, target, skip) {
  let setup = 0
  const est = records.map(e => {
    const n = (e.sql?.length ?? 0) + setup + 1.6 * (clean(e.result) + clean(e.reuse))
    if (e.sql && stateful(e.sql)) setup += e.sql.length + 40
    return n
  })
  const total = est.reduce((a, b) => a + b, 0)
  if (total <= target) return records
  const seen = new Set()
  const pick = records.map(() => false)
  let used = 0
  records.forEach((e, i) => { if (!e.result || stateful(e.sql ?? '')) { pick[i] = true; used += est[i] } })
  records.forEach((e, i) => {
    if (pick[i]) return
    const sig = JSON.stringify([e.result?.errors?.map(x => x.number), e.result?.sets?.map(s => s.columns.map(c => `${c.type}:${c.length}:${c.precision}:${c.scale}`))])
    if (!seen.has(sig) && used + est[i] <= target / 3) { pick[i] = true; used += est[i] }
    seen.add(sig)
  })
  const rest = records.reduce((n, e, i) => n + (pick[i] ? 0 : est[i]), 0)
  const k = Math.max(1, Math.ceil(rest / Math.max(1, target - used)))
  records.forEach((e, i) => { if (!pick[i] && stableIndex(e.name) % k === 0) pick[i] = true })
  const kept = records.filter((e, i) => pick[i])
  if (records.length - kept.length) skip('sampled out (grid)', records.length - kept.length)
  return kept
}
const stableIndex = name => createHash('sha256').update(String(name)).digest().readUInt32LE(0)

// Grid: independent cases, each replaying earlier stateful records as setup.
function grid(records, { budget = 200_000, skip, rename = e => e.name, extra = () => ({}) } = {}) {
  const chosen = new Set(sample(records, budget, skip))
  const setup = []
  const entries = []
  for (const e of records) {
    const isState = e.sql && !isPrepared(e) && stateful(e.sql)
    if (chosen.has(e)) {
      const entry = entryOf(e, { name: rename(e), ...extra(e) })
      if (entry.steps) entry.steps = [...setup.map(s => ({ ...s })), ...entry.steps]
      entries.push(entry)
    }
    if (isState) {
      const own = entryOf(e, extra(e))
      if (own.steps) setup.push(...own.steps.map(({ expect, ...s }) => s))
    }
  }
  return [{ id: 'grid', independent: true, entries }]
}

const records = doc => doc.containers[0].runs[0]
const gridAdapter = (budget = 200_000) => (doc, { skip }) => grid(records(doc), { budget, skip })

// cursor: raw DONE tokens {kind, status, curCmd, rowCount: string}.
function cursorExpect(result, { dropLine = false } = {}) {
  const clean = cleanColumns(result)
  if (dropLine) clean.errors = clean.errors.map(({ lineNumber, ...e }) => e)
  const std = standardExpect({ ...clean, done: undefined }, { keys: ['sets', 'errors', 'info', 'returnStatus', 'rowCount'] })
  const value = { ...std.value, done: result.done }
  return customExpect(value, actual => ({
    ...std.project(actual),
    done: actual.tokens.map(t => ({ kind: doneKind(t.name), status: doneStatus(t), curCmd: t.curCmd, rowCount: String(typeof t.rowCount === 'number' ? t.rowCount : 0) })),
  }))
}

// isjson-depth: the @j value is generated from `input` (capture script valueFor).
function isjsonValue(input) {
  const d = input.depth
  switch (input.form) {
    case 'array': return '['.repeat(d) + '0' + ']'.repeat(d)
    case 'object': return '{"v":'.repeat(d) + '0' + '}'.repeat(d)
    case 'invalid-before-depth': return '[x' + '['.repeat(d - 1) + '0' + ']'.repeat(d)
    case 'invalid-after-depth': return '['.repeat(d) + 'x' + ']'.repeat(d)
    case 'unclosed-after-depth': return '['.repeat(d) + '0' + ']'.repeat(d - 1)
    case 'empty-array': return '['.repeat(d) + ']'.repeat(d)
    case 'empty-object': return '{"v":'.repeat(d - 1) + '{}' + '}'.repeat(d - 1)
    case 'empty-at-depth': return '['.repeat(d) + ']'.repeat(d)
    case 'incomplete-after-depth': return '['.repeat(d) + '1e' + ']'.repeat(d)
    case 'openings-only': return '['.repeat(d)
    case 'trailing-after-depth': return '['.repeat(d) + '0' + ']'.repeat(d) + 'x'
    case 'units': return String.fromCharCode(...input.units)
    default: return undefined
  }
}

const withMode = e => e.mode ? `${e.name} (${e.mode})` : e.name

export default {
  'charindex-patindex': gridAdapter(),
  'compress-decompress': gridAdapter(),
  'concat-boundary': gridAdapter(),
  'concat-legacy-family': gridAdapter(),
  'concat-numeric-format': gridAdapter(),
  'concat-text-conversion': gridAdapter(),
  'concat-ws-translate': gridAdapter(),
  'datetrunc-bucket': gridAdapter(200_000),
  'decimal-unicode': gridAdapter(),
  format: gridAdapter(200_000),
  'greatest-least': gridAdapter(200_000),
  'hashbytes-checksum': gridAdapter(),
  'isjson-coercion': (doc, { skip }) => grid(records(doc), { skip, rename: withMode }),
  'isjson-depth': (doc, { skip }) => grid(records(doc), {
    skip, rename: withMode,
    extra: e => { const v = isjsonValue(e.input); return v === undefined ? {} : { rpcParams: [{ name: 'j', type: 'NVarChar', value: v, options: { length: 'max' } }] } },
  }),
  'isjson-source-types': (doc, { skip }) => grid(records(doc), { skip, rename: withMode }),
  'json-advanced-path': gridAdapter(),
  'json-aggregates': gridAdapter(),
  'json-constructors': gridAdapter(),
  'json-extraction-boundaries': gridAdapter(),
  'json-extraction-wildcard': gridAdapter(),
  'like-patterns': (doc, { skip }) => {
    const r = records(doc)
    skip('prepared protocol (sp_prepare/sp_execute)', r.prepared?.length ?? 0)
    return grid(r.records, { skip })
  },
  'offset-functions': (doc, { skip }) => {
    const r = records(doc)
    skip('prepared protocol (sp_prepare/sp_execute)', r.prepared?.length ?? 0)
    return grid(r.records, { skip })
  },
  'parse-try-parse': gridAdapter(),
  'soundex-difference': gridAdapter(),
  'string-agg': gridAdapter(),
  'string-split': gridAdapter(),
  'temporal-parts': gridAdapter(),
  // Exhaustive grids (58-98 MB each, concat-family capture with COLMETADATA
  // descriptors and a reuse probe): heavy sampling.
  'float-default-grid': gridAdapter(250_000),
  'temporal-guid-format': gridAdapter(250_000),
  'translate-ascii-matching': gridAdapter(250_000),
  'translate-character-matching': gridAdapter(250_000),

  // Sequential: @@DBTS advances with every rowversion write.
  rowversion: doc => [{ id: 'run', entries: records(doc).map(e => entryOf(e)) }],

  // Sequential, batch/rpc/procedure modes; rpc parameters are not recorded
  // in the fixture (capture-table-variable.mjs passes @p int).
  'table-variable': doc => {
    const rpcParams = { 'rpc declaration and bound value': [['p', 'Int', 7]], 'rpc caller cannot see table variable': [['p', 'Int', 9]] }
    return [{
      id: 'run',
      entries: records(doc).map(e => {
        if (e.mode === 'prepared') return { name: e.name, skip: 'prepared protocol (sp_prepare/sp_execute)', stateless: true }
        const entry = entryOf(e, { rpcParams: rpcParams[e.name] })
        if (entry.steps && e.mode === 'procedure') entry.steps = [{ ...entry.steps[0], kind: 'proc' }]
        if (entry.steps && e.mode === 'rpc') entry.steps[0].kind = 'rpc'
        return entry
      }),
    }]
  },

  // Sequential on the primary session; the secondary session (visibility of
  // another session's changes) cannot be expressed, so the run stops there.
  cursor: doc => [{
    id: 'run',
    entries: records(doc).map(e => {
      if (e.session !== 'primary') return { name: e.name, skip: 'multi-connection (secondary session)' }
      if (e.kind === 'prepared') return { name: e.name, skip: 'prepared protocol (sp_prepare/sp_execute)', stateless: true }
      if (e.result.truncated) return { name: e.name, skip: 'bounded capture overflowed', stateless: true }
      const expect = cursorExpect(e.result, { dropLine: Boolean(e.variesByContainer) })
      const step = { kind: e.kind === 'procedure' ? 'proc' : e.kind === 'rpc' ? 'rpc' : 'batch', sql: e.sql, expect }
      if (e.parameters) step.params = e.parameters.map(p => tediousParam(p))
      return { name: e.name, steps: [step] }
    }),
  }],
}

