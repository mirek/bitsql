// Parser vs SQL Server on every captured batch (see src/parse-diff.mjs).
// Disagreements listed in harness/parse-known.txt are tolerated (a roadmap,
// not a regression); any other disagreement fails.
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { parseDiff } from '../src/parse-diff.mjs'

const known = new Set(readFileSync(new URL('../parse-known.txt', import.meta.url), 'utf8').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#')))

test('parser agrees with SQL Server on syntax errors across the corpus', async t => {
  const { total, disagreements } = await parseDiff()
  const fresh = disagreements.filter(d => !known.has(d.id))
  const now = new Set(disagreements.map(d => d.id))
  const fixed = [...known].filter(id => !now.has(id))
  if (fixed.length) t.diagnostic(`${fixed.length} parse-known.txt entr${fixed.length === 1 ? 'y now agrees' : 'ies now agree'}; remove: ${fixed.slice(0, 5).join(', ')}`)
  t.diagnostic(`${disagreements.length - fresh.length} known disagreement(s) of ${total} batches`)
  if (fresh.length) {
    const sample = fresh.slice(0, 5).map(d => `${d.id}: bitsql ${d.ours} / sql server ${d.sqlServer ?? 'parses'}`).join('\n')
    throw new Error(`${fresh.length} of ${total} batches disagree:\n${sample}`)
  }
})
