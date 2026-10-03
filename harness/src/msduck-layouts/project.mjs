// Shared helpers for the msduck layout adapters (import-msduck-layouts.mjs).
//
// An adapter turns one msduck reference file into runs:
//   Run   = { id, independent?, entries: Entry[] }
//   Entry = { name, steps?: Step[], skip?: reason }
//   Step  = { kind: 'batch'|'rpc'|'proc', sql, params?, expect?: Expect }
//   Expect = { value, project(actualStepCapture) -> comparable }
// Entries of a run execute in order on one connection. Every entry with at
// least one expecting step becomes a case: the steps of all earlier entries
// of the run replay first as uncompared setup (unless `independent`), then
// the entry's own steps (steps without `expect` are uncompared setup).
// An entry with `skip` is not executed (and not replayed); the reason is
// counted in _import.json, and the rest of a sequential run is skipped too
// (its state would differ) unless the entry is marked `stateless: true`.
// An entry without expecting steps is setup only.
import { isDeepStrictEqual } from 'node:util'

export const DB_NAMES = /msduck_audit_[0-9a-f]{32}|<fresh-database>/g
export const scrub = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value).replace(DB_NAMES, '{db}'))
export const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60)
const isMissing = v => v === undefined || (v && typeof v === 'object' && !Array.isArray(v) && v.kind === 'missing' && Object.keys(v).length === 1)

// Projects `actual` onto the shape of `expected`: objects keep only the keys
// the expectation has, arrays map element-wise. Anything the expectation
// does not record is ignored; anything it records must match exactly.
export function projectLike(actual, expected) {
  if (Array.isArray(expected) && Array.isArray(actual)) {
    return actual.map((x, i) => i < expected.length ? projectLike(x, expected[i]) : x)
  }
  if (expected && typeof expected === 'object' && actual && typeof actual === 'object' && !Array.isArray(actual) && !Array.isArray(expected)) {
    return Object.fromEntries(Object.keys(expected).map(k => [k, projectLike(actual[k], expected[k])]))
  }
  return actual
}

export const STANDARD_KEYS = ['sets', 'done', 'errors', 'info', 'returnStatus', 'rowCount']

// Normalizes the scalar quirks of msduck's capture: returnStatus/rowCount
// recorded as undefined ({kind:'missing'}) mean null in bitsql captures.
function normalizeStandard(result, keys) {
  const out = {}
  for (const key of keys) {
    if (!(key in result)) continue
    let v = result[key]
    if ((key === 'returnStatus' || key === 'rowCount') && isMissing(v)) v = null
    out[key] = v
  }
  // client-side errors (no number/state) cannot be compared meaningfully
  return out
}

// The common msduck capture {sets, done, errors, info, returnStatus, rowCount}
// (any subset, extra keys ignored). `keys` limits what is compared.
export function standardExpect(result, { keys = STANDARD_KEYS, transform } = {}) {
  const value = normalizeStandard(scrub(result), keys)
  return {
    value,
    project: actual => {
      const picked = normalizeStandard(actual, Object.keys(value))
      return projectLike(transform ? transform(picked, actual) : picked, value)
    },
  }
}

// Explicit projection: `value` is compared with `fn(actual)` exactly.
export const customExpect = (value, fn) => ({ value: scrub(value), project: fn })

// Token sequence helpers over bitsql's `stream`/`tokens` capture.
export const doneStatus = t => (t.more ? 1 : 0) | (t.sqlError ? 2 : 0) | (t.rowCount !== undefined && t.rowCount !== null && t.rowCount?.kind !== 'missing' ? 0x10 : 0) | (t.attention ? 0x20 : 0) | (t.serverError ? 0x100 : 0)
export const doneKind = name => ({ DONE: 'done', DONEPROC: 'doneProc', DONEINPROC: 'doneInProc' })[name] ?? name

export function firstMismatch(expect, actualCapture) {
  if (!actualCapture) return { path: '/', actual: '<missing>', expected: 'capture' }
  let projected
  try { projected = expect.project(actualCapture) } catch (error) { return { path: '/project', actual: error.message, expected: null } }
  if (isDeepStrictEqual(projected, expect.value)) return null
  return firstPath(projected, expect.value, '')
}

function firstPath(a, b, path) {
  if (isDeepStrictEqual(a, b)) return null
  const kind = v => v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v
  if (kind(a) !== kind(b) || (kind(a) !== 'array' && kind(a) !== 'object')) return { path: path || '/', actual: short(a), expected: short(b) }
  if (kind(a) === 'array') {
    for (let i = 0; i < Math.min(a.length, b.length); i++) { const d = firstPath(a[i], b[i], `${path}/${i}`); if (d) return d }
    return { path: `${path}/length`, actual: a.length, expected: b.length }
  }
  for (const k of new Set([...Object.keys(b), ...Object.keys(a)])) { const d = firstPath(a[k], b[k], `${path}/${k}`); if (d) return d }
  return null
}
const short = v => { const s = JSON.stringify(v); return s === undefined ? '<missing>' : s.length > 160 ? s.slice(0, 160) + '…' : JSON.parse(s) }

// msduck records RPC parameters as tedious type names ([name, 'NVarChar',
// value, options?]); corpus params use T-SQL type text.
export function tediousParam([name, typeName, value, options], { output = false } = {}) {
  let type = String(typeName).toLowerCase()
  if (options?.length !== undefined) type += `(${options.length === Infinity || options.length === 'max' ? 'max' : options.length})`
  else if (options?.precision !== undefined) type += `(${options.precision}${options.scale !== undefined ? `,${options.scale}` : ''})`
  else if (options?.scale !== undefined) type += `(${options.scale})`
  return { name: String(name).replace(/^@/, ''), type, value: paramValue(value), ...(output ? { output: true } : {}) }
}
// canonical msduck values -> corpus JSON literals (binary hex, dates ISO, bigint string)
export function paramValue(v) {
  if (v && typeof v === 'object' && v.kind) {
    if (v.kind === 'binary' || v.kind === 'bigint' || v.kind === 'date') return v.value
    if (v.kind === 'missing') return null
  }
  return v
}
