// npm run capture -- [selector...] [--force] [--concurrency N]
//
// Runs corpus cases against the real SQL Server oracle and stores the
// expected output next to each case. Existing expectations are never
// overwritten unless --force is given together with explicit selectors.
import { readFile } from 'node:fs/promises'
import { relative } from 'node:path'
import { corpusDir, parseArgs, useUtcTimeZone } from './env.mjs'
import { loadCorpus, readExpected } from './corpus.mjs'
import { oracleTarget, pool, runCase, toExpected } from './runner.mjs'
import { writeJson } from './json.mjs'

useUtcTimeZone()
const { flags, positionals } = parseArgs(process.argv.slice(2), { booleans: ['force'] })
if (flags.force && !positionals.length) {
  console.error('--force needs explicit selectors (e.g. npm run capture -- --force traps/collation.sql)')
  process.exit(2)
}
const cases = await loadCorpus(positionals)
const todo = []
for (const c of cases) if (flags.force || !(await readExpected(c))) todo.push(c)
if (!todo.length) { console.log(`nothing to capture (${cases.length} case(s) already have expectations; use --force with selectors to recapture)`); process.exit(0) }

const target = await oracleTarget({ log: text => process.stderr.write(text) })
console.log(`capturing ${todo.length} case(s) on SQL Server ${target.server.version}`)
const results = await pool(todo, Number(flags.concurrency ?? 4), async c => {
  const outcome = toExpected(c, await runCase(target, c))
  const summary = outcome.error ? `FAILED ${outcome.error}` : outcome.expected.steps.filter(Boolean).map(s => `${s.sets.length} set(s)${s.errors.length ? ` ${s.errors.length} error(s) [${s.errors.map(e => e.number).join(',')}]` : ''}`).join('; ')
  console.log(`${outcome.error ? '!!' : 'ok'} ${c.id}: ${summary}`)
  return { c, outcome }
})

// Group by expectation file; multi-case files are merged key by key.
const byFile = new Map()
for (const r of results) {
  if (r.outcome.error) continue
  if (!byFile.has(r.c.expectedFile)) byFile.set(r.c.expectedFile, [])
  byFile.get(r.c.expectedFile).push(r)
}
for (const [file, entries] of byFile) {
  const server = { image: target.server.image, version: target.server.version }
  if (entries[0].c.key === null) {
    await writeJson(file, { server, ...entries[0].outcome.expected }, { overwrite: Boolean(flags.force) })
  } else {
    let doc
    try { doc = JSON.parse(await readFile(file, 'utf8')) } catch (error) { if (error.code !== 'ENOENT') throw error; doc = { server, cases: {} } }
    for (const { c, outcome } of entries) {
      if (doc.cases[c.key] && !flags.force) continue
      doc.cases[c.key] = { ...outcome.expected, ...(doc.server?.version !== server.version ? { server } : {}) }
    }
    await writeJson(file, doc, { overwrite: true })
  }
  console.log(`wrote ${relative(corpusDir, file)}`)
}
const failed = results.filter(r => r.outcome.error).length
if (failed) { console.error(`${failed} case(s) could not be captured`); process.exitCode = 1 }
