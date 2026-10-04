// Parse differential: does bitsql's parser accept exactly the corpus batches
// SQL Server accepts, and reject the others with the same syntax error number?
// Needs no server: runs the `parsecheck` binary over every batch/rpc step and
// compares with the captured errors. Usage: npm run parse-diff [-- selectors]
import { spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, readdirSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { repoDir } from './env.mjs'
import { loadCorpus, readExpected } from './corpus.mjs'

// Errors the parser itself raises; any other captured error means SQL Server parsed the batch.
// Named-window (4123, 5362-5367, 16211) and NEXT VALUE FOR … OVER (117xx)
// errors are resolved while parsing too (parse/window.mbt).
export const SYNTAX_ERRORS = new Set([102, 103, 105, 111, 113, 155, 156, 191, 319, 497, 1018, 1034, 10713,
  4123, 5362, 5364, 5365, 5366, 5367, 16211, 11716, 11717, 11718, 11737])

function parsecheckBinary() {
  if (process.env.BITSQL_PARSECHECK) return process.env.BITSQL_PARSECHECK
  const build = spawnSync('moon', ['build', '--target', 'native'], { cwd: repoDir, encoding: 'utf8' })
  if (build.status !== 0) throw new Error(`moon build failed:\n${build.stderr}`)
  const path = join(repoDir, '_build/native/debug/build/parsecheck/parsecheck.exe')
  statSync(path)
  return path
}

export async function parseDiff(selectors = []) {
  const items = []
  for (const c of await loadCorpus(selectors)) {
    const expected = await readExpected(c)
    if (!expected) continue
    c.steps.forEach((step, i) => {
      if (step.kind !== 'batch' && step.kind !== 'rpc' || !step.sql) return
      // Replayed run prefixes are checked in the case that captured them.
      if (step.replay) return
      const errors = (expected.steps?.[i]?.errors ?? []).map(e => e.number)
      items.push({ id: `${c.id} step ${i}`, sql: step.sql, syntax: errors.filter(n => SYNTAX_ERRORS.has(n)) })
    })
  }
  const dir = mkdtempSync(join(tmpdir(), 'bitsql-parse-'))
  const input = join(dir, 'batches.json')
  writeFileSync(input, JSON.stringify(items.map(x => x.sql)))
  const run = spawnSync(parsecheckBinary(), ['--json', input, '--all'], { encoding: 'utf8', maxBuffer: 1 << 28 })
  if (run.status !== 0) throw new Error(`parsecheck failed: ${run.stderr}`)
  const lines = run.stdout.split('\n')
  const disagreements = []
  items.forEach((item, i) => {
    // every syntax error of the batch, in order (parser error recovery)
    const out = lines[i]
    const ours = out === 'ok' ? '' : out
    const theirs = item.syntax.join(' ')
    if (ours !== theirs) disagreements.push({ id: item.id, ours: out, sqlServer: theirs || null, sql: item.sql.slice(0, 200) })
  })
  return { total: items.length, disagreements }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { total, disagreements } = await parseDiff(process.argv.slice(2))
  for (const d of disagreements) console.log(`${d.id}\n  bitsql: ${d.ours}\n  sql server: ${d.sqlServer ?? 'parses'}\n  ${d.sql.replace(/\n/g, ' ')}`)
  console.log(`${total} batches, ${disagreements.length} parse disagreements`)
  process.exit(disagreements.length ? 1 : 0)
}
