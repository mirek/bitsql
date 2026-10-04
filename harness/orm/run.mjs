// ORM compatibility suite: runs each ORM workload against the SQL Server
// oracle and against bitsql, each in its own fresh database, and compares
// what the application observes step by step: returned data, errors (numbers
// and messages) and the SQL the tool logged.
//
//   npm test                         every workload, both targets, compare
//   npm test -- knex typeorm         selected workloads
//   npm test -- --only emulator knex print the emulator trace, no comparison
//   ORM_DEBUG=1 npm test -- knex     print every step error with its stack
//
// Targets: the oracle container bitsql-oracle (127.0.0.1:47314, started or
// reused like `npm run oracle:start` in ../) and the emulator (BITSQL_ADDR,
// BITSQL_BIN or `moon build` + spawn, like ../src/emulator.mjs).
//
// Exit status 1 when any step diverges, except divergences listed in
// known.json ({"<workload>/<step>": "reason"}): those are printed as known.
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Trace } from './lib/trace.mjs'
import { compareTraces } from './lib/compare.mjs'
import { oracle, emulator, freshDatabase, dropDatabase } from './lib/targets.mjs'

process.env.TZ = 'UTC'
// Some ORMs reject promises nobody awaits (TypeORM startTransaction on a
// closed driver); they must not end the run.
process.on('unhandledRejection', error => { if (process.env.ORM_DEBUG) console.error('unhandled rejection:', error) })
const here = dirname(fileURLToPath(import.meta.url))
const all = ['knex', 'sequelize', 'typeorm', 'prisma']

const args = process.argv.slice(2)
let only = null
const selected = []
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--only') only = args[++i]
  else selected.push(args[i])
}
const workloads = selected.length ? selected : all
for (const w of workloads) if (!all.includes(w)) { console.error(`unknown workload ${w} (${all.join(', ')})`); process.exit(2) }

const known = JSON.parse(await readFile(join(here, 'known.json'), 'utf8').catch(() => '{}'))
const log = s => process.stderr.write(s)

const targets = []
try {
  if (only !== 'emulator') targets.push(await oracle({ log }))
  if (only !== 'oracle') targets.push(await emulator({ log }))
} catch (error) {
  console.error(`orm suite: ${error.message}`)
  for (const t of targets) await t.stop()
  process.exit(1)
}

async function runOn(target, name) {
  const database = `bitsql_orm_${name}`
  const t = { ...target, database }
  const trace = new Trace({ target: target.name, database })
  const started = Date.now()
  try {
    await freshDatabase(t, database)
    const { default: workload } = await import(`./workloads/${name}.mjs`)
    await workload(t, trace)
  } catch (error) {
    trace.steps.push({ name: '(workload aborted)', error: { type: error?.constructor?.name, message: trace.norm.str(String(error?.message ?? error)).split('\n')[0] } })
    if (process.env.ORM_DEBUG) console.error(error)
  }
  if (target.name === 'oracle') await dropDatabase(t, database)
  trace.ms = Date.now() - started
  return trace
}

const report = { workloads: {} }
let failures = 0
for (const name of workloads) {
  const traces = await Promise.all(targets.map(t => runOn(t, name)))
  const byTarget = Object.fromEntries(traces.map(t => [t.target, t]))
  const entry = { traces: Object.fromEntries(traces.map(t => [t.target, { ms: t.ms, steps: t.steps }])) }
  if (traces.length === 1) {
    const t = traces[0]
    console.log(`== ${name} on ${t.target} (${t.steps.length} steps, ${t.ms} ms)`)
    for (const s of t.steps) {
      console.log(`-- ${s.name}${s.error ? `  ERROR ${JSON.stringify(s.error)}` : ''}`)
      if (process.env.ORM_VERBOSE) {
        if ('value' in s) console.log('   value: ' + JSON.stringify(s.value).slice(0, 2000))
        for (const q of s.sql ?? []) console.log('   sql: ' + q.slice(0, 2000))
      }
    }
  } else {
    const diffs = compareTraces(byTarget.oracle, byTarget.emulator)
    entry.diffs = diffs
    const fresh = diffs.filter(d => !known[`${name}/${d.step}`])
    const old = diffs.filter(d => known[`${name}/${d.step}`])
    const total = byTarget.oracle.steps.length
    console.log(`== ${name}: ${total - diffs.length}/${total} steps match (oracle ${byTarget.oracle.ms} ms, emulator ${byTarget.emulator.ms} ms)${old.length ? `, ${old.length} known` : ''}`)
    for (const d of fresh) {
      failures++
      console.log(`   DIFF ${d.step}: ${d.path}`)
      console.log(`        oracle:   ${JSON.stringify(d.expected)?.slice(0, 600)}`)
      console.log(`        emulator: ${JSON.stringify(d.actual)?.slice(0, 600)}`)
    }
    for (const d of old) console.log(`   known ${d.step}: ${known[`${name}/${d.step}`]}`)
  }
  report.workloads[name] = entry
}

await mkdir(join(here, 'out'), { recursive: true })
await writeFile(join(here, 'out', 'report.json'), JSON.stringify(report, null, 1))
for (const t of targets) await t.stop()
console.log(`report: harness/orm/out/report.json${failures ? `; ${failures} unexpected divergence(s)` : ''}`)
process.exit(failures ? 1 : 0)
