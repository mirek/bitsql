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
export const SYNTAX_ERRORS = new Set([102, 103, 105, 111, 113, 155, 156, 191, 319, 497, 1018, 10713])

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
  const run = spawnSync(parsecheckBinary(), ['--json', input], { encoding: 'utf8', maxBuffer: 1 << 28 })
  if (run.status !== 0) throw new Error(`parsecheck failed: ${run.stderr}`)
  const lines = run.stdout.split('\n')
  const disagreements = []
  items.forEach((item, i) => {
    const out = lines[i]
    const ours = out === 'ok' ? null : Number(out.split(' ')[0])
    const theirs = item.syntax[0] ?? null
    if (ours !== theirs) disagreements.push({ id: item.id, ours: out, sqlServer: theirs, sql: item.sql.slice(0, 200) })
  })
  return { total: items.length, disagreements }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { total, disagreements } = await parseDiff(process.argv.slice(2))
  for (const d of disagreements) console.log(`${d.id}\n  bitsql: ${d.ours}\n  sql server: ${d.sqlServer ?? 'parses'}\n  ${d.sql.replace(/\n/g, ' ')}`)
  console.log(`${total} batches, ${disagreements.length} parse disagreements`)
  process.exit(disagreements.length ? 1 : 0)
}
