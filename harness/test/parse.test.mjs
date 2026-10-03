// Parser vs SQL Server on every captured batch (see src/parse-diff.mjs).
import { test } from 'node:test'
import { parseDiff } from '../src/parse-diff.mjs'

test('parser agrees with SQL Server on syntax errors across the corpus', async () => {
  const { total, disagreements } = await parseDiff()
  if (disagreements.length) {
    const sample = disagreements.slice(0, 5).map(d => `${d.id}: bitsql ${d.ours} / sql server ${d.sqlServer ?? 'parses'}`).join('\n')
    throw new Error(`${disagreements.length} of ${total} batches disagree:\n${sample}`)
  }
})
