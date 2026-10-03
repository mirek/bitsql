// npm run import:msduck -- [--from <msduck checkout>] [--max-bytes N] [--no-verify] [--force]
//
// Converts msduck reference/*.json captures (SQL Server 2025, same image
// family) in the clean layout { image, version, results: [{ query, reference,
// tokens?, setup?, readback?, after?, value? }] } into corpus cases with their
// expected output: harness/corpus/msduck/<file>.cases.json + .expected.json.
//
// Execution mode per entry (msduck kept no explicit flag):
//   *-rpc.json and raiserror-failure-counter.json  -> rpc (tedious execSql)
//   entries with `value`                            -> rpc with @s nvarchar
//   entries with `parameters` (sp_prepare/execute)  -> skipped (no prepared mode yet)
//   everything else                                 -> batch
// `setup` becomes an uncompared setup step; `readback` + `after` becomes a
// compared batch step. With verification (default) every imported case is
// run against the local oracle and kept only if it reproduces exactly, so
// a wrong mode guess or a version difference never becomes an expectation.
import { mkdir, readdir, readFile, stat, writeFile, rm } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { corpusDir, parseArgs, useUtcTimeZone } from './env.mjs'
import { caseHash, exists } from './corpus.mjs'
import { oracleTarget, pool, runCase } from './runner.mjs'
import { compareCase } from './compare.mjs'
import { formatJson } from './json.mjs'

useUtcTimeZone()
const { flags } = parseArgs(process.argv.slice(2), { booleans: ['no-verify', 'force'] })
const from = resolve(flags.from ?? process.env.MSDUCK_DIR ?? join(process.env.TMPDIR ?? tmpdir(), 'msduck'))
const maxBytes = Number(flags['max-bytes'] ?? 1024 * 1024)
const outDir = join(corpusDir, 'msduck')
const referenceDir = join(from, 'reference')
if (!await exists(referenceDir)) {
  console.error(`no ${referenceDir}; git clone --depth 1 https://github.com/mirek/msduck.git "$TMPDIR/msduck" or pass --from`)
  process.exit(2)
}
if (await exists(outDir) && (await readdir(outDir)).length && !flags.force) {
  console.error(`${outDir} is not empty; pass --force to regenerate the imported corpus`)
  process.exit(2)
}

const RPC_FILES = /-rpc\.json$|^raiserror-failure-counter\.json$/
const DB_NAMES = /msduck_audit_[0-9a-f]{32}/g
const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60)
const versionOf = v => typeof v === 'string' ? v : JSON.stringify(v ?? '').match(/\d+\.\d+\.\d+\.\d+/)?.[0] ?? null
const scrub = value => JSON.parse(JSON.stringify(value).replace(DB_NAMES, '{db}'))
const doneTokens = tokens => tokens?.filter(t => /^DONE/.test(t.name)).map(t => ({ name: t.name, more: t.more, sqlError: t.sqlError, attention: t.attention, serverError: t.serverError, rowCount: t.rowCount ?? { kind: 'missing' }, curCmd: t.curCmd ?? t.command }))

const stats = { files: 0, tooBig: 0, otherLayout: 0, entries: 0, imported: 0, skipped: {} }
const skip = (reason, n = 1) => { stats.skipped[reason] = (stats.skipped[reason] ?? 0) + n }
const suites = []
for (const name of (await readdir(referenceDir)).filter(f => f.endsWith('.json')).sort()) {
  const path = join(referenceDir, name)
  if ((await stat(path)).size > maxBytes) { stats.tooBig++; continue }
  const doc = JSON.parse(await readFile(path, 'utf8'))
  if (!Array.isArray(doc.results) || !doc.results.every(r => r.query !== undefined && r.reference)) { stats.otherLayout++; continue }
  stats.files++
  const rpcFile = RPC_FILES.test(name)
  const cases = []
  doc.results.forEach((entry, index) => {
    stats.entries++
    if (entry.parameters !== undefined) return skip('prepared protocol (sp_prepare/sp_execute)')
    if (typeof entry.query !== 'string') return skip('non-string query')
    if (entry.readback && !entry.after) return skip('readback without capture')
    const steps = []
    const expected = []
    if (entry.setup) { steps.push({ kind: 'batch', sql: entry.setup, compare: false }); expected.push(null) }
    const rpc = rpcFile || entry.value !== undefined
    const step = { kind: rpc ? 'rpc' : 'batch', sql: entry.query }
    if (entry.value !== undefined) step.params = [{ name: 's', type: 'nvarchar', value: entry.value }]
    steps.push(step)
    const reference = scrub(entry.reference)
    const tokens = doneTokens(entry.tokens)
    expected.push(tokens?.length ? { ...reference, tokens } : reference)
    if (entry.readback) { steps.push({ kind: 'batch', sql: entry.readback }); expected.push(scrub(entry.after)) }
    const key = `${String(index).padStart(3, '0')}${entry.name ? `-${slug(entry.name)}` : ''}`
    cases.push({ key, name: entry.name, steps, expected: { case: caseHash(steps), steps: expected } })
  })
  if (cases.length) suites.push({ file: name, base: name.replace(/\.json$/, ''), image: doc.image, version: versionOf(doc.version), cases })
}

// Verify on the oracle: keep only cases it reproduces exactly.
const verify = !flags['no-verify']
let failures = []
if (verify) {
  const target = await oracleTarget({ log: text => process.stderr.write(text) })
  const all = suites.flatMap(s => s.cases.map(c => ({ s, c })))
  console.error(`verifying ${all.length} imported case(s) against SQL Server ${target.server.version}`)
  let n = 0
  await pool(all, Number(flags.concurrency ?? 6), async ({ s, c }) => {
    const actual = await runCase(target, { id: `${s.base}#${c.key}`, steps: c.steps })
    const failure = compareCase(actual, c.expected)
    if (failure) { c.rejected = failure; failures.push({ id: `${s.base}#${c.key}`, kind: failure.kind, path: failure.path }) }
    if (++n % 100 === 0) console.error(`  ${n}/${all.length}`)
  })
}

await rm(outDir, { recursive: true, force: true })
await mkdir(outDir, { recursive: true })
let bytes = 0
for (const s of suites) {
  const kept = s.cases.filter(c => !c.rejected)
  if (!kept.length) continue
  const source = `msduck/reference/${s.file}`
  const casesDoc = { source, image: s.image, cases: kept.map(c => ({ name: c.key, ...(c.name ? { description: c.name } : {}), steps: c.steps })) }
  const expectedDoc = { source, server: { image: s.image, version: s.version }, cases: Object.fromEntries(kept.map(c => [c.key, c.expected])) }
  const a = formatJson(casesDoc) + '\n', b = formatJson(expectedDoc) + '\n'
  await writeFile(join(outDir, `${s.base}.cases.json`), a)
  await writeFile(join(outDir, `${s.base}.expected.json`), b)
  bytes += Buffer.byteLength(a) + Buffer.byteLength(b)
  stats.imported += kept.length
}
if (verify) skip('not reproduced by local oracle', failures.length)
const kinds = {}
for (const f of failures) kinds[f.kind] = (kinds[f.kind] ?? 0) + 1
await writeFile(join(outDir, '_import.json'), formatJson({
  source: 'https://github.com/mirek/msduck reference/*.json (clean results layout)', maxBytes, verified: verify, stats, bytes,
  rejectedKinds: Object.fromEntries(Object.entries(kinds).sort((x, y) => y[1] - x[1])), rejected: failures.sort((x, y) => x.id.localeCompare(y.id)),
}) + '\n')
console.log(formatJson({ ...stats, bytes, rejectedKinds: kinds }))
