// msduck layout adapters: `run` layouts (gaps-transactions, savepoint).
import { standardExpect, tediousParam } from './project.mjs'

// Whole files that cannot be expressed as corpus steps.
const unrepresentable = (reason, count) => (doc, { skip }) => { skip(reason, count(doc)); return [] }
const firstRunLength = doc => (Array.isArray(doc.results) ? doc.results.length : Array.isArray(doc.runs?.[0]) ? doc.runs[0].length : doc.runs?.[0]?.observations?.length ?? 1)

// at-time-zone-history-*: { baseline, samples, boundaries?, localBoundaries?, chunks }
// of clean {query, reference} entries; the per-year `chunks` grids (tens of
// MB) are skipped, localBoundaries sampled every 10th.
function timeZoneHistory(doc, { skip }) {
  const entries = []
  const add = (name, e) => entries.push({ name, steps: [{ kind: 'batch', sql: e.query, expect: standardExpect(e.reference) }] })
  if (doc.baseline) add('baseline', doc.baseline)
  doc.samples?.forEach((e, i) => add(`sample ${i}`, e))
  doc.boundaries?.forEach(e => add(`boundary ${e.name}`, e))
  doc.localBoundaries?.forEach((e, i) => { if (i % 10 === 0) add(`local ${e.name} ${e.time}`, e); else skip('sampled out (grid)') })
  skip('exhaustive grid chunk (too large)', doc.chunks?.length ?? 0)
  return [{ id: 'grid', independent: true, entries }]
}

const historyFiles = ['0001-0499', '0500-0999', '1000-1499', '1500-1799', '1800-1899', '1900-2050', '2051-2100', '2101-2500']

export default {
  ...Object.fromEntries(historyFiles.map(y => [`at-time-zone-history-${y}`, timeZoneHistory])),
  attention: unrepresentable('attention (cancel) requests', firstRunLength),
  'attention-boundaries': unrepresentable('attention (cancel) requests', firstRunLength),
  'attention-compute': unrepresentable('attention (cancel) requests', firstRunLength),
  'bulk-character-capacity': unrepresentable('bulk load (BCP)', firstRunLength),
  'bulk-character-conversion': unrepresentable('bulk load (BCP)', firstRunLength),
  'bulk-character-cp1252': unrepresentable('bulk load (BCP)', firstRunLength),
  'bulk-character-encoding': unrepresentable('bulk load (BCP)', firstRunLength),
  'bulk-load-wire': unrepresentable('bulk load (BCP)', firstRunLength),
  'bulk-staging-reference': unrepresentable('bulk load (BCP)', firstRunLength),
  'tvp-binding': unrepresentable('table-valued parameters', firstRunLength),
  'tvp-default': unrepresentable('table-valued parameters', firstRunLength),
  'tvp-wire': unrepresentable('table-valued parameters', firstRunLength),
  'login-database-error': unrepresentable('login-time behavior (no SQL step)', firstRunLength),

  // { runs: [[{name, query, result, packets, headers, responses, tokens}]], independentRuns }
  // execSqlBatch per entry on one connection; raw packets are not comparable,
  // the decoded result is the standard capture.
  'for-xml-wire': doc => [{ id: 'run', entries: doc.runs[0].map(e => ({ name: e.name, steps: [{ kind: 'batch', sql: e.query, expect: standardExpect(e.result) }] })) }],

  // { run: [{name, sql, result, wait?, waited?} | {name, request, args, error}], snapshot: {run: [{connection, ...}]} }
  // One connection. Transaction-manager requests (tedious beginTransaction &c)
  // cannot be expressed as corpus steps; the run restarts as a fresh segment
  // at 'isolation reset', which does not depend on that section. The
  // `snapshot` section needs three connections and is skipped.
  'gaps-transactions': (doc, { skip }) => {
    const segments = [{ id: 'run', entries: [] }]
    for (const e of doc.run) {
      if (e.name === 'isolation reset') segments.push({ id: 'waitfor', independent: true, entries: [] })
      const entries = segments.at(-1).entries
      if (e.request) { entries.push({ name: e.name, skip: 'transaction manager request' }); continue }
      if (e.name === 'server identity') { entries.push({ name: e.name, skip: 'server version probe', stateless: true }); continue }
      entries.push({ name: e.name, steps: [{ kind: 'batch', sql: e.sql, expect: standardExpect(e.result) }] })
    }
    skip('multi-connection (snapshot section)', doc.snapshot?.run?.length ?? 0)
    return segments
  },

  // { run: [{program, name, kind: batch|rpc|procedure|transaction-manager|prepared, ...}] }
  // Programs run one after another on one connection; each works on its own
  // table and ends with a cleanup that rolls back, so every program is its
  // own run (earlier programs' tables are not needed).
  savepoint: doc => {
    const runs = new Map()
    for (const e of doc.run) {
      if (e.program === 'session') continue
      if (!runs.has(e.program)) runs.set(e.program, { id: e.program, entries: [] })
      const entries = runs.get(e.program).entries
      const name = `${e.program} ${e.name}`
      if (e.name === 'before' && /^DROP TABLE dbo\.svp_basic,/.test(e.sql)) entries.push({ name, skip: 'drops tables of earlier programs (programs are separate runs)', stateless: true })
      else if (e.kind === 'batch') entries.push({ name, steps: [{ kind: 'batch', sql: e.sql, expect: standardExpect(e.result) }] })
      else if (e.kind === 'rpc') entries.push({ name, steps: [{ kind: 'rpc', sql: e.sql, params: e.parameters.map(p => tediousParam(p)), expect: standardExpect(e.result) }] })
      else if (e.kind === 'procedure') entries.push({ name, steps: [{ kind: 'proc', sql: e.procedure, params: e.parameters.map(p => tediousParam(p)), expect: standardExpect(e.result) }] })
      else if (e.kind === 'transaction-manager') entries.push({ name, skip: 'transaction manager request' })
      else if (e.kind === 'prepared') entries.push({ name, skip: 'prepared protocol (sp_prepare/sp_execute)' })
      else entries.push({ name, skip: `unknown kind ${e.kind}` })
    }
    return [...runs.values()]
  },
}
