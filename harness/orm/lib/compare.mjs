// Step-by-step comparison of two traces: the first difference per step.

function firstDifference(expected, actual, path = '') {
  if (expected === actual) return null
  if (typeof expected !== typeof actual || expected === null || actual === null || typeof expected !== 'object') {
    return { path: path || '/', expected, actual }
  }
  if (Array.isArray(expected) !== Array.isArray(actual)) return { path: path || '/', expected, actual }
  if (Array.isArray(expected)) {
    for (let i = 0; i < Math.min(expected.length, actual.length); i++) {
      const d = firstDifference(expected[i], actual[i], `${path}/${i}`)
      if (d) return d
    }
    if (expected.length !== actual.length) {
      const i = Math.min(expected.length, actual.length)
      return { path: `${path}/length`, expected: expected.length > i ? expected.slice(i, i + 3) : expected.length, actual: actual.length > i ? actual.slice(i, i + 3) : actual.length }
    }
    return null
  }
  const keys = new Set([...Object.keys(expected), ...Object.keys(actual)])
  for (const k of keys) {
    if (!(k in actual)) return { path: `${path}/${k}`, expected: expected[k], actual: '(missing)' }
    if (!(k in expected)) return { path: `${path}/${k}`, expected: '(missing)', actual: actual[k] }
    const d = firstDifference(expected[k], actual[k], `${path}/${k}`)
    if (d) return d
  }
  return null
}

export function compareTraces(oracle, emulator) {
  const diffs = []
  const n = Math.max(oracle.steps.length, emulator.steps.length)
  for (let i = 0; i < n; i++) {
    const e = oracle.steps[i]
    const a = emulator.steps[i]
    if (!e || !a || e.name !== a.name) {
      diffs.push({ step: e?.name ?? a?.name, path: '/step', expected: e?.name ?? null, actual: a?.name ?? null })
      continue
    }
    const pick = s => ({ error: s.error ?? null, value: 'value' in s ? s.value : null, sql: s.sql })
    const ex = pick(e)
    const ac = pick(a)
    if (e.sql === null || a.sql === null) { ex.sql = null; ac.sql = null }
    const d = firstDifference(ex, ac)
    if (d) diffs.push({ step: e.name, ...d })
  }
  return diffs
}
