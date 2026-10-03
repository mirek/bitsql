// npm run diff -- [selector...] [--target emulator|oracle] [--isolation database|process]
//                 [--concurrency N] [--show N] [--verbose]
//
// Runs corpus cases against the emulator (default) or the oracle, compares
// with the captured expectations and prints failures grouped by the kind of
// their first difference, largest group first. Writes harness/out/report.json.
import { mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { outDir, parseArgs, useUtcTimeZone } from './env.mjs'
import { loadCorpus, readExpected } from './corpus.mjs'
import { emulatorTarget, oracleTarget, pool, runCase } from './runner.mjs'
import { compareCase } from './compare.mjs'
import { writeJson } from './json.mjs'

useUtcTimeZone()
const { flags, positionals } = parseArgs(process.argv.slice(2), { booleans: ['verbose'] })
const targetName = flags.target ?? 'emulator'
const cases = await loadCorpus(positionals)
const withExpectation = []
const missing = []
for (const c of cases) { const e = await readExpected(c); if (e) withExpectation.push({ c, e }); else missing.push(c.id) }

let target
try {
  target = targetName === 'oracle'
    ? await oracleTarget({ log: text => process.stderr.write(text) })
    : await emulatorTarget({ isolation: flags.isolation, log: text => process.stderr.write(text) })
} catch (error) {
  console.error(error.message)
  process.exit(1)
}
if (flags.isolation && target.isolation !== flags.isolation) target.isolation = flags.isolation

const started = Date.now()
let done = 0
const concurrency = Number(flags.concurrency ?? (targetName === 'oracle' ? 4 : 8))
const outcomes = await pool(withExpectation, concurrency, async ({ c, e }) => {
  const actual = await runCase(target, c)
  const failure = compareCase(actual, e)
  if (++done % 100 === 0) process.stderr.write(`  ${done}/${withExpectation.length}\n`)
  if (flags.verbose) console.log(`${failure ? 'FAIL' : 'pass'} ${c.id}${failure ? ` — ${failure.kind}` : ''}`)
  return { id: c.id, source: c.source, failure, actual: failure ? actual : undefined }
})
await target.stop?.()

const failures = outcomes.filter(o => o.failure)
const groups = new Map()
for (const f of failures) {
  if (!groups.has(f.failure.kind)) groups.set(f.failure.kind, [])
  groups.get(f.failure.kind).push(f)
}
const ranked = [...groups.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]))
const report = {
  target: targetName, server: target.server, isolation: target.isolation,
  totals: { cases: cases.length, compared: outcomes.length, passed: outcomes.length - failures.length, failed: failures.length, noExpectation: missing.length },
  durationMs: Date.now() - started,
  groups: ranked.map(([kind, list]) => ({ kind, count: list.length, cases: list.map(f => f.id) })),
  failures: failures.map(f => ({ id: f.id, ...f.failure })),
  passed: outcomes.filter(o => !o.failure).map(o => o.id),
  noExpectation: missing,
}
await mkdir(outDir, { recursive: true })
await writeJson(join(outDir, 'report.json'), report, { overwrite: true })

const show = Number(flags.show ?? 15)
const t = report.totals
console.log(`\n${targetName}: ${t.passed}/${t.compared} passed, ${t.failed} failed${t.noExpectation ? `, ${t.noExpectation} without expectation (run npm run capture)` : ''}`)
if (ranked.length) {
  console.log('\nFailures by first-difference kind (ranked):')
  for (const [kind, list] of ranked.slice(0, show)) {
    const first = list[0].failure
    console.log(`${String(list.length).padStart(5)}  ${kind}`)
    console.log(`         e.g. ${list.slice(0, 3).map(f => f.id).join(', ')}${list.length > 3 ? ', …' : ''}`)
    console.log(`         ${first.path}: actual ${JSON.stringify(first.actual)?.slice(0, 120)} expected ${JSON.stringify(first.expected)?.slice(0, 120)}`)
  }
  if (ranked.length > show) console.log(`  … ${ranked.length - show} more kinds in out/report.json`)
}
console.log('\nreport: harness/out/report.json')
process.exitCode = failures.length ? 1 : 0
