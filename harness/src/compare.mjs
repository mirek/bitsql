// Compares a run result with a stored expectation and classifies the first
// difference into a "kind" used to rank failures.
import { firstDifference, preview } from './capture-core.mjs'

// Errors first: an unexpected error explains everything after it.
const KEY_ORDER = ['errors', 'sets', 'info', 'done', 'returnStatus', 'rowCount', 'outputs', 'tokens', 'stream']

function orderedKeys(object) {
  const keys = Object.keys(object)
  return [...KEY_ORDER.filter(k => keys.includes(k)), ...keys.filter(k => !KEY_ORDER.includes(k))]
}

function compareCapture(actual, expected, base) {
  if (!actual) return { path: base, actual: '<missing>', expected: 'capture' }
  for (const key of orderedKeys(expected)) {
    let value = actual[key]
    // Metadata-only expectations (some msduck imports) omit `rows`.
    if (key === 'sets' && Array.isArray(value) && Array.isArray(expected.sets)) {
      value = value.map((set, i) => expected.sets[i] && !('rows' in expected.sets[i]) ? { columns: set.columns } : set)
    }
    const d = firstDifference(value, expected[key], `${base}/${key}`)
    if (d) return d
  }
  return null
}

export function kindOf(diff, actualCapture) {
  const local = diff.path.replace(/^\/(steps\/\d+|reuse)\//, '').replace(/\/\d+(?=\/|$)/g, '/*')
  const scope = diff.path.startsWith('/reuse') ? 'reuse ' : ''
  // An explicit "not supported" anywhere in the step explains the difference.
  const unsupported = (actualCapture?.errors ?? []).find(e => /^Emulator:/.test(e.message ?? ''))
  if (unsupported) return `${scope}unsupported: ${unsupported.message.slice(0, 60)}`
  if (local.startsWith('errors')) {
    const actualErrors = actualCapture?.errors ?? []
    const index = Number(/^\/(?:steps\/\d+|reuse)\/errors\/(\d+)/.exec(diff.path)?.[1] ?? 0)
    const error = actualErrors[index] ?? actualErrors[0]
    if (error && /^Emulator:/.test(error.message ?? '')) return `${scope}unsupported: ${error.message.slice(0, 60)}`
    if (error?.client) return `${scope}client error: ${String(error.code ?? error.message).slice(0, 60)}`
    if (error && diff.expected === '<missing>') return `${scope}unexpected error ${error.number}`
    // More errors than expected: name the first extra one.
    if (local === 'errors/length' && typeof diff.actual === 'number' && diff.actual > diff.expected) {
      const extra = actualErrors[diff.expected]
      if (extra?.client) return `${scope}client error: ${String(extra.code ?? extra.message).slice(0, 60)}`
      if (extra) return `${scope}unexpected error ${extra.number}`
    }
  }
  return `${scope}${local}`
}

// Returns null when equal, else { kind, path, actual, expected }.
export function compareCase(actual, expected) {
  for (const key of ['connectError', 'transportError', 'isolationError']) {
    if (actual[key]) return { kind: key.replace('Error', ''), path: '/', actual: preview(actual[key]), expected: null }
  }
  if (expected.case && actual.case !== expected.case) return { kind: 'stale expectation (case edited after capture)', path: '/case', actual: actual.case, expected: expected.case }
  const steps = expected.steps ?? []
  for (let i = 0; i < steps.length; i++) {
    if (steps[i] === null) continue
    const d = compareCapture(actual.steps?.[i], steps[i], `/steps/${i}`)
    if (d) {
      // An explicit "not supported" in an earlier (setup) step is the root cause.
      const earlier = (actual.steps ?? []).slice(0, i).flatMap(s => s?.errors ?? []).find(e => /^Emulator:/.test(e.message ?? ''))
      if (earlier && !/unsupported/.test(kindOf(d, actual.steps?.[i]))) return { kind: `unsupported in setup: ${earlier.message.slice(0, 60)}`, ...d }
      return { kind: kindOf(d, actual.steps?.[i]), ...d }
    }
  }
  if (expected.reuse) {
    const d = compareCapture(actual.reuse, expected.reuse, '/reuse')
    if (d) return { kind: kindOf(d, actual.reuse), ...d }
  }
  return null
}
