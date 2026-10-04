// npm run probe -- file.sql [oracle|emulator|both]: runs a corpus-format
// .sql case (no expectation needed) and prints columns, rows, errors and
// the token stream per step. For exploring SQL Server before writing cases.
// Runs the corpus-format case on the target(s) and prints a compact view.
import { readFile } from 'node:fs/promises'
import { parseSqlCase } from './corpus.mjs'
import { oracleTarget, emulatorTarget, runCase } from './runner.mjs'

const [file, which = 'both'] = process.argv.slice(2)
const text = await readFile(file, 'utf8')
const steps = parseSqlCase(text)

function compact(step) {
  if (!step) return 'null'
  const out = []
  for (const s of step.sets ?? []) {
    out.push('  cols: ' + s.columns.map(c => `${c.name}:${c.type}(${c.length ?? ''},${c.precision ?? ''},${c.scale ?? ''}) f${c.flags}${c.collation ? ' ' + JSON.stringify(c.collation) : ''}`).join(' | '))
    for (const r of (s.rows ?? []).slice(0, 40)) out.push('  row: ' + JSON.stringify(r))
  }
  for (const e of step.errors ?? []) out.push(`  ERR ${e.number} st${e.state} cl${e.class} ln${e.lineNumber}: ${e.message}`)
  for (const e of step.info ?? []) out.push(`  INFO ${e.number} st${e.state} cl${e.class}: ${e.message}`)
  if (step.tokens) out.push('  tokens: ' + JSON.stringify(step.tokens))
  if (step.stream) out.push('  stream: ' + JSON.stringify(step.stream).slice(0, 600))
  return out.join('\n')
}

const targets = []
if (which !== 'emulator') targets.push(await oracleTarget())
if (which !== 'oracle') targets.push(await emulatorTarget({ isolation: 'process' }))
for (const t of targets) {
  const r = await runCase(t, { steps })
  console.log(`===== ${t.name}`)
  if (r.connectError || r.transportError || r.isolationError) console.log(r)
  r.steps?.forEach((s, i) => { console.log(`--- step ${i}: ${steps[i].sql.slice(0, 160).replace(/\n/g, ' ')}`); console.log(compact(s)) })
  t.stop?.()
}
process.exit(0)
