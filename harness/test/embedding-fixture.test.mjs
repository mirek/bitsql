// Keep the generated pure tests tied to the SQL/HTTP inputs actually captured.
// SQL inference itself is still tested separately once host integration lands.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { embeddingCases } from '../gen/embedding-cases.mjs'

test('embedding fixture inputs match the captured SQL Server HTTP exchanges', async () => {
  const captured = JSON.parse(await readFile(new URL('../fixtures/embeddings.expected.json', import.meta.url), 'utf8'))
  assert.deepEqual(captured.cases.map(c => c.input), embeddingCases)
  assert.match(captured.server.version, /^17\./)
  for (const c of captured.cases) {
    assert.equal(c.result.errors.some(e => e.client), false, c.input.name)
    assert.equal(c.result.errors.some(e => e.class >= 20), Boolean(c.input.fatal), c.input.name)
  }
})
