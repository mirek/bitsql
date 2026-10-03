// Full-fidelity capture of one request through tedious, ported from msduck
// scripts/lib/compatibility.mjs (capture/canonical/differences) and
// scripts/lib/reference.mjs (bounded first-difference description).
//
// A capture records what a tedious client can observe:
//   sets:   [{ columns: [{name,type,length,precision,scale,flags,collation}], rows }]
//   done:   [{ kind: done|doneInProc|doneProc, rowCount, more }]
//   errors / info: [{ number, state, class, lineNumber, message }]
//   returnStatus, rowCount (request callback), outputs (RETURNVALUE)
//   tokens: DONE-family tokens with curCmd and status bits (msduck layout)
//   stream: the compact token sequence (ROW runs collapsed), bitsql only
import { Request } from 'tedious'
import { isDeepStrictEqual } from 'node:util'
import { resolveType } from './types.mjs'

const messageFields = m => ({ number: m.number, state: m.state, class: m.class, lineNumber: m.lineNumber, message: m.message })
export const columnFields = c => ({ name: c.colName, type: c.type.name, length: c.dataLength ?? null, precision: c.precision ?? null, scale: c.scale ?? null, flags: c.flags, collation: canonical(c.collation ?? null) })

function streamEntry(token) {
  switch (token.name) {
    case 'DONE': case 'DONEINPROC': case 'DONEPROC':
      return { name: token.name, status: (token.more ? 1 : 0) | (token.sqlError ? 2 : 0) | (token.rowCount !== undefined ? 0x10 : 0) | (token.attention ? 0x20 : 0) | (token.serverError ? 0x100 : 0), curCmd: token.curCmd }
    case 'ERROR': case 'INFO': return { name: token.name, number: token.number }
    case 'ENVCHANGE': return { name: token.name, type: token.type }
    case 'RETURNSTATUS': return { name: token.name, value: token.value }
    case 'RETURNVALUE': return { name: token.name, param: token.paramName }
    case 'ORDER': return { name: token.name, columns: token.orderColumns }
    case 'COLMETADATA': return { name: token.name, columns: token.columns?.length }
    default: return { name: token.name }
  }
}

// Runs one step on `connection`. step: { kind: 'batch'|'rpc'|'proc', sql, params? }
// Never rejects: transport/client failures land in `errors` with `client: true`.
export function capture(connection, step, { rowLimit = 100000 } = {}) {
  return new Promise(resolve => {
    const result = { sets: [], done: [], errors: [], info: [], returnStatus: null, outputs: [], tokens: [], stream: [] }
    let truncated = 0
    let finished = false
    const previousToken = connection.debug.token
    const finish = (error, rowCount) => {
      if (finished) return
      finished = true
      connection.debug.token = previousToken
      connection.off('errorMessage', onError)
      connection.off('infoMessage', onInfo)
      result.rowCount = rowCount ?? null
      // Server errors arrive through errorMessage; only client-side failures
      // (validation, timeout, socket) are recorded from the callback.
      if (error && !result.errors.length) result.errors.push({ client: true, code: error.code ?? null, message: error.message, number: error.number ?? null })
      if (truncated) result.truncatedRows = truncated
      resolve(result)
    }
    const onError = e => result.errors.push(messageFields(e))
    const onInfo = e => result.info.push(messageFields(e))
    connection.on('errorMessage', onError)
    connection.on('infoMessage', onInfo)
    // tedious calls debug.token for every parsed token, listeners or not.
    connection.debug.token = token => {
      if (token.name.startsWith('DONE')) result.tokens.push({ name: token.name, more: token.more, sqlError: token.sqlError, attention: token.attention, serverError: token.serverError, rowCount: token.rowCount, curCmd: token.curCmd })
      const entry = streamEntry(token)
      const last = result.stream.at(-1)
      if ((entry.name === 'ROW' || entry.name === 'NBCROW') && last?.name === entry.name) last.count++
      else result.stream.push(entry.name === 'ROW' || entry.name === 'NBCROW' ? { name: entry.name, count: 1 } : entry)
    }
    // tedious keeps a RETURNSTATUS on the connection until a DONEPROC clears
    // it, so an earlier request's status could leak into this one (msduck).
    if ('procReturnStatusValue' in connection) connection.procReturnStatusValue = undefined
    const request = new Request(step.sql, (error, rowCount) => finish(error, rowCount))
    request.on('columnMetadata', metadata => result.sets.push({ columns: metadata.map(columnFields), rows: [] }))
    request.on('row', row => {
      const set = result.sets.at(-1)
      if (set.rows.length >= rowLimit) truncated++
      else set.rows.push(row.map(c => c.value))
    })
    for (const kind of ['done', 'doneInProc', 'doneProc']) request.on(kind, (rowCount, more) => result.done.push({ kind, rowCount: rowCount ?? null, more }))
    request.on('doneProc', (_count, _more, status) => { if (status !== undefined) result.returnStatus = status })
    request.on('returnValue', (name, value, metadata) => result.outputs.push({ name, type: metadata?.type?.name ?? null, length: metadata?.dataLength ?? null, precision: metadata?.precision ?? null, scale: metadata?.scale ?? null, value }))
    try {
      for (const p of step.params ?? []) {
        const { type, options } = resolveType(p.type)
        const value = p.value === undefined ? null : decodeParamValue(p.type, p.value)
        if (p.output) request.addOutputParameter(p.name.replace(/^@/, ''), type, value, options)
        else request.addParameter(p.name.replace(/^@/, ''), type, value, options)
      }
      if (step.kind === 'batch') connection.execSqlBatch(request)
      else if (step.kind === 'rpc') connection.execSql(request)
      else if (step.kind === 'proc') connection.callProcedure(request)
      else throw new Error(`unknown step kind ${step.kind}`)
    } catch (error) { finish(error) }
  })
}

// Parameter values in corpus files are JSON. Binary values are hex strings,
// dates ISO strings, bigint decimal strings.
function decodeParamValue(typeText, value) {
  if (value === null) return null
  const base = typeText.toLowerCase().replace(/\(.*$/, '').trim()
  if (['binary', 'varbinary', 'image'].includes(base)) return Buffer.from(String(value).replace(/^0x/i, ''), 'hex')
  if (['date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset', 'time'].includes(base) && typeof value === 'string') {
    if (base === 'time') return new Date(`1970-01-01T${value}Z`)
    return new Date(value)
  }
  return value
}

// Convenience for scripts: run a batch and return { rows, columns, errors }.
export async function query(connection, sql) {
  const result = await capture(connection, { kind: 'batch', sql })
  if (result.errors.length) throw new Error(result.errors.map(e => e.message).join('; '))
  return { rows: result.sets[0]?.rows ?? [], columns: result.sets[0]?.columns ?? [], sets: result.sets }
}

export function canonical(value) {
  if (value === undefined) return { kind: 'missing' }
  if (typeof value === 'bigint') return { kind: 'bigint', value: value.toString() }
  if (Buffer.isBuffer(value)) return { kind: 'binary', value: value.toString('hex') }
  if (value instanceof Date) return {
    kind: 'date', value: Number.isNaN(value.getTime()) ? 'Invalid Date' : value.toISOString(),
    ...(value.nanosecondsDelta === undefined ? {} : { nanosecondsDelta: value.nanosecondsDelta }),
  }
  if (typeof value === 'number' && !Number.isFinite(value)) return { kind: 'number', value: String(value) }
  if (typeof value === 'number' && Object.is(value, -0)) return { kind: 'number', value: '-0' }
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, canonical(v)]))
  return value
}

// Replaces every occurrence of `name` inside strings (messages, values) with
// `{db}`, so captures from differently named case databases compare equal.
export function replaceDatabaseName(value, name) {
  if (!name) return value
  const pattern = name instanceof RegExp ? name : new RegExp(`(?<![\\w@#$])${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\w@#$])`, 'g')
  if (typeof value === 'string') return value.replace(pattern, '{db}')
  if (Array.isArray(value)) return value.map(v => replaceDatabaseName(v, pattern))
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, replaceDatabaseName(v, pattern)]))
  return value
}

// JSON-pointer diff (msduck). Returns every differing leaf.
export function differences(actual, expected, path = '') {
  if (Object.is(actual, expected)) return []
  if (actual && expected && typeof actual === 'object' && typeof expected === 'object' && Array.isArray(actual) === Array.isArray(expected)) {
    const keys = new Set([...Object.keys(actual), ...Object.keys(expected)])
    return [...keys].flatMap(key => differences(actual[key], expected[key], `${path}/${key.replaceAll('~', '~0').replaceAll('/', '~1')}`))
  }
  return [{ path: path || '/', actual: actual === undefined ? { kind: 'missing' } : actual, expected: expected === undefined ? { kind: 'missing' } : expected }]
}

// The first difference in document order, with array length mismatches
// reported at the array (not at its first missing element). Bounded: never
// serializes whole captures (node:assert on big captures OOMs, msduck).
export function firstDifference(actual, expected, path = '') {
  if (isDeepStrictEqual(actual, expected)) return null
  const kindOf = v => v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v
  const ka = kindOf(actual), kb = kindOf(expected)
  if (ka !== kb || (ka !== 'array' && ka !== 'object')) return { path: path || '/', actual: preview(actual), expected: preview(expected) }
  if (ka === 'array') {
    const n = Math.min(actual.length, expected.length)
    for (let i = 0; i < n; i++) { const d = firstDifference(actual[i], expected[i], `${path}/${i}`); if (d) return d }
    return { path: `${path}/length`, actual: actual.length, expected: expected.length }
  }
  const keys = [...new Set([...Object.keys(expected), ...Object.keys(actual)])]
  for (const k of keys) { const d = firstDifference(actual[k], expected[k], `${path}/${k}`); if (d) return d }
  return null
}

export function preview(value, limit = 200) {
  if (value === undefined) return '<missing>'
  const text = JSON.stringify(value)
  return text.length > limit ? `${text.slice(0, limit)}…(${text.length} chars)` : JSON.parse(text)
}
