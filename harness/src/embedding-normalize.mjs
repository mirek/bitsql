import assert from 'node:assert/strict'

// Volatile sources differ between runs, but the actual HTTP input must equal
// the SQL value returned by that same run. Check this before normalization.
export function normalizeEmbeddingExecution(value) {
  const c = JSON.parse(JSON.stringify(value))
  if (c.input.volatileSource) {
    assert.deepEqual(c.result.errors, [], c.input.name + ': SQL errors')
    const source = c.result.sets[0].rows[0][0]
    assert.equal(typeof source, 'string')
    assert.ok(source.length > 0)
    assert.equal(c.requests.length, 1, c.input.name + ': request count')
    assert.equal(JSON.parse(c.requests[0].body).input, source, c.input.name + ': source was reevaluated')
    c.result.sets[0].rows[0][0] = '{volatile-source}'
    c.requests[0].body = c.requests[0].body.replace(JSON.stringify(source), '"{volatile-source}"')
  }
  return c
}
