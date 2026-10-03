// npm run import:msduck-layouts -- [--from <msduck checkout>] [--only a,b] [--no-verify]
//                                   [--no-recheck] [--concurrency N] [--list]
//                                   [--dry-run [--report out.json]]
// --dry-run verifies but writes nothing under corpus/ (per-file stats and
// rejection details go to stdout and --report).
//
// Imports msduck reference/*.json captures that are NOT in the clean
// `{results:[{query, reference}]}` layout (import-msduck.mjs handles those):
// sequential runs (`runs`, `run`, `cases/steps`, `groups`, `observations`,
// rpc entries, ...). Each layout has an adapter in src/msduck-layouts/ that
// yields runs of entries (see project.mjs for the shape).
//
// Every entry of a sequential run becomes its own case whose earlier run
// steps replay as uncompared setup (shared once per file through the
// cases.json `runs` table), so pass/fail is per step. Verification (default):
// each case runs on the local oracle; it is kept only if the projection of
// the oracle capture equals msduck's recorded result, and then a second run
// must reproduce the full harness capture exactly (determinism). The stored
// expectation is the oracle's capture in the harness format (toExpected).
//
// Output: corpus/msduck-gaps/ (gaps-*.json) and corpus/msduck-runs/ (the
// rest), one <file>.cases.json + .expected.json per source file, plus
// _import.json per directory with per-file counts and rejection reasons.
import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { corpusDir, parseArgs, useUtcTimeZone } from './env.mjs'
import { caseHash, exists, expandSteps } from './corpus.mjs'
import { oracleTarget, pool, runCase, toExpected } from './runner.mjs'
import { compareCase } from './compare.mjs'
import { formatJson } from './json.mjs'
import { firstMismatch, slug } from './msduck-layouts/project.mjs'
import { adapters } from './msduck-layouts/index.mjs'

useUtcTimeZone()
const { flags } = parseArgs(process.argv.slice(2), { booleans: ['no-verify', 'no-recheck', 'list', 'dry-run'] })
const from = resolve(flags.from ?? process.env.MSDUCK_DIR ?? join(process.env.TMPDIR || tmpdir(), 'msduck'))
const referenceDir = join(from, 'reference')
if (!await exists(referenceDir)) {
  console.error(`no ${referenceDir}; git clone --depth 1 https://github.com/mirek/msduck.git "$TMPDIR/msduck" or pass --from`)
  process.exit(2)
}
const only = flags.only ? new Set(String(flags.only).split(',').map(s => s.trim().replace(/\.json$/, ''))) : null
const outDirFor = base => join(corpusDir, base.startsWith('gaps-') ? 'msduck-gaps' : 'msduck-runs')
const scriptText = async name => readFile(join(from, 'scripts', name), 'utf8')

if (flags.list) { console.log(Object.keys(adapters).sort().join('\n')); process.exit(0) }

// 1. Adapt every selected file into cases.
const files = []
for (const base of Object.keys(adapters).sort()) {
  if (only && !only.has(base)) continue
  const path = join(referenceDir, `${base}.json`)
  const stats = { entries: 0, cases: 0, imported: 0, skipped: {}, rejected: {} }
  const skip = (reason, n = 1) => { stats.skipped[reason] = (stats.skipped[reason] ?? 0) + n }
  if (!await exists(path)) { skip('file missing in msduck checkout'); files.push({ base, stats, cases: [], runs: {} }); continue }
  const doc = JSON.parse(await readFile(path, 'utf8'))
  let runs
  try { runs = await adapters[base](doc, { base, scriptText, skip }) }
  catch (error) { console.error(`${base}: adapter failed: ${error.stack}`); process.exit(1) }
  const cases = []
  const runSteps = {}
  const keys = new Set()
  let index = 0
  for (const run of runs) {
    const executed = []
    let poisoned = null
    for (const entry of run.entries) {
      stats.entries++
      const n = index++
      if (poisoned && !run.independent) { skip(`after an unrepresentable step (${poisoned})`); continue }
      if (entry.skip) { skip(entry.skip); if (!entry.stateless) poisoned = entry.skip; continue }
      const steps = entry.steps ?? []
      if (!steps.length) { skip('entry without steps'); continue }
      const own = steps.map(({ expect, ...s }) => (expect ? { ...s } : { ...s, compare: false }))
      if (steps.some(s => s.expect)) {
        let key = `${String(n).padStart(3, '0')}${entry.name ? `-${slug(entry.name)}` : ''}`
        while (keys.has(key)) key += '_'
        keys.add(key)
        const prefix = run.independent ? 0 : executed.length
        const c = { name: key, ...(entry.name ? { description: entry.name } : {}), ...(prefix ? { run: run.id, prefix } : {}), steps: own }
        const expanded = expandSteps({ runs: { [run.id]: executed } }, c)
        cases.push({ c, expanded, expects: [...Array(prefix).fill(null), ...steps.map(s => s.expect ?? null)] })
        stats.cases++
      }
      if (!run.independent) executed.push(...own.map(({ compare, ...s }) => s))
    }
    runSteps[run.id] = executed
  }
  files.push({ base, stats, cases, runs: runSteps, source: `msduck/reference/${base}.json`, image: doc.image ?? doc.containers?.[0]?.image, version: doc.version })
}
const all = files.flatMap(f => f.cases.map(c => ({ f, c })))
console.error(`${files.length} file(s), ${all.length} case(s) to verify`)

// 2. Verify on the oracle (msduck projection, then determinism).
const reject = (f, c, reason) => { c.rejected = reason; f.stats.rejected[reason] = (f.stats.rejected[reason] ?? 0) + 1 }
const kindOfPath = path => path.replace(/\/\d+(?=\/|$)/g, '/*')
let target = { server: null }
if (!flags['no-verify'] && all.length) {
  target = await oracleTarget({ log: text => process.stderr.write(text) })
  console.error(`verifying against SQL Server ${target.server.version}`)
  let n = 0
  await pool(all, Number(flags.concurrency ?? 6), async ({ f, c }) => {
    const testCase = { id: `${f.base}#${c.c.name}`, steps: c.expanded }
    const actual = await runCase(target, testCase)
    const outcome = toExpected(testCase, actual)
    if (outcome.error) reject(f, c, `oracle run failed: ${outcome.error.slice(0, 60)}`)
    else {
      for (let i = 0; i < c.expects.length && !c.rejected; i++) {
        if (!c.expects[i]) continue
        const d = firstMismatch(c.expects[i], actual.steps[i])
        if (d) { reject(f, c, `msduck mismatch ${kindOfPath(d.path)}`); c.mismatch = d }
      }
      if (!c.rejected) {
        c.expected = outcome.expected
        if (!flags['no-recheck']) {
          const again = compareCase(await runCase(target, testCase), c.expected)
          if (again) reject(f, c, `nondeterministic ${again.kind}`)
        }
      }
    }
    if (++n % 50 === 0) console.error(`  ${n}/${all.length}`)
  })
}

// 3. Write the corpus files and per-directory stats.
const rejectedOf = f => f.cases.filter(c => c.rejected).map(c => ({ id: c.c.name, reason: c.rejected, ...(c.mismatch ? { path: c.mismatch.path, actual: c.mismatch.actual, expected: c.mismatch.expected } : {}) }))
if (flags['dry-run']) {
  for (const f of files) f.stats.imported = f.cases.filter(c => !c.rejected && (c.expected || flags['no-verify'])).length
  if (flags.report) await writeFile(resolve(flags.report), formatJson(Object.fromEntries(files.map(f => [f.base, { ...f.stats, rejectedCases: rejectedOf(f) }]))) + '\n')
}
const byDir = new Map()
for (const f of files) {
  const dir = outDirFor(f.base)
  if (!byDir.has(dir)) byDir.set(dir, [])
  byDir.get(dir).push(f)
}
for (const [dir, list] of flags['dry-run'] ? [] : byDir) {
  await mkdir(dir, { recursive: true })
  const statsFile = join(dir, '_import.json')
  let summary = { source: 'https://github.com/mirek/msduck reference/*.json (sequential and other layouts; src/import-msduck-layouts.mjs)', verified: !flags['no-verify'], files: {} }
  if (only && await exists(statsFile)) summary = JSON.parse(await readFile(statsFile, 'utf8'))
  for (const f of list) {
    for (const ext of ['.cases.json', '.expected.json']) await rm(join(dir, f.base + ext), { force: true })
    const kept = f.cases.filter(c => !c.rejected && (c.expected || flags['no-verify']))
    f.stats.imported = kept.length
    const rejectedIds = rejectedOf(f)
    let bytes = 0
    if (kept.length) {
      const usedPrefix = {}
      for (const { c } of kept) if (c.run) usedPrefix[c.run] = Math.max(usedPrefix[c.run] ?? 0, c.prefix)
      const runs = Object.fromEntries(Object.entries(usedPrefix).map(([id, n]) => [id, f.runs[id].slice(0, n)]))
      const casesDoc = { source: f.source, image: f.image, ...(Object.keys(runs).length ? { runs } : {}), cases: kept.map(k => k.c) }
      const a = formatJson(casesDoc) + '\n'
      await writeFile(join(dir, `${f.base}.cases.json`), a)
      bytes += Buffer.byteLength(a)
      if (!flags['no-verify']) {
        const expectedDoc = { source: f.source, server: target.server, msduck: { image: f.image, version: typeof f.version === 'string' ? f.version : undefined }, cases: Object.fromEntries(kept.map(k => [k.c.name, k.expected])) }
        const b = formatJson(expectedDoc) + '\n'
        await writeFile(join(dir, `${f.base}.expected.json`), b)
        bytes += Buffer.byteLength(b)
      }
    }
    summary.files[f.base] = { ...f.stats, bytes, rejectedCases: rejectedIds }
  }
  summary.files = Object.fromEntries(Object.entries(summary.files).sort(([a], [b]) => a.localeCompare(b)))
  const totals = { entries: 0, cases: 0, imported: 0, bytes: 0, skipped: {}, rejected: {} }
  for (const s of Object.values(summary.files)) {
    for (const k of ['entries', 'cases', 'imported', 'bytes']) totals[k] += s[k] ?? 0
    for (const k of ['skipped', 'rejected']) for (const [r, n] of Object.entries(s[k] ?? {})) totals[k][r] = (totals[k][r] ?? 0) + n
  }
  for (const k of ['skipped', 'rejected']) totals[k] = Object.fromEntries(Object.entries(totals[k]).sort((x, y) => y[1] - x[1]))
  summary.totals = totals
  await writeFile(statsFile, formatJson(summary) + '\n')
  console.log(`${dir}: ${totals.imported}/${totals.cases} case(s) kept from ${totals.entries} entries, ${totals.bytes} bytes`)
}
for (const f of files) console.log(`${f.base.padEnd(40)} entries ${String(f.stats.entries).padStart(4)} cases ${String(f.stats.cases).padStart(4)} kept ${String(f.stats.imported).padStart(4)}  skipped ${JSON.stringify(f.stats.skipped)} rejected ${JSON.stringify(f.stats.rejected)}`)
