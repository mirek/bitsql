// msduck layout adapters: gaps-b group (see project.mjs for the Run/Entry shape).
// Keys are msduck reference file base names; values (doc, ctx) => Run[].
//
// gaps-computed / gaps-keys / gaps-rowversion_identity / gaps-unicode-predicates
//   { cases: [{ id, steps: [{ sql, result, completion }] }] }: each case runs
//   its steps in order in a fresh database (one run per case). `completion`
//   is the DONE-family tokens as tedious parsed them (debug.token).
// gaps-bulk: same, but steps `{ step, result }` where a step is SQL or a
//   tedious bulk load (skipped; it poisons the rest of the case).
// gaps-constraints: { groups: [{ name, steps: [{ sql, result: {errors, info, sets: [rows]} }] }] }
// gaps-functions: { cases: [{ name, results }] } — the batches live only in
//   the capture script (evaluated from its `cases` literal).
// gaps-outer_dml: { cases: [{ name, setup, dml, readback, result: {dml, readback} }] }
// gaps-temp_tables: { results: [{ name, session: A|B|C, mode: batch|rpc, sql, result }] }
// gaps-triggers: { cases: [{ name, batches: [{ sql, sets: [{columns: [names], rows}], errors, info, done: raw DONE }] }] }
import { customExpect, doneKind, doneStatus, scrub, standardExpect, tediousParam } from './project.mjs'

// msduck redactions of the fresh database name -> bitsql's {db}.
const dbScrub = v => scrub(JSON.parse(JSON.stringify(v).replace(/msduck_audit_<database>/g, '{db}')))
const replaceIn = (v, re, to) => JSON.parse(JSON.stringify(v).replace(re, to))

// `completion`: [{name, handlerName?, more, sqlError, attention, serverError, rowCount?, curCmd}]
const tokenView = t => ({
  name: t.name, more: t.more, sqlError: t.sqlError, attention: t.attention, serverError: t.serverError,
  rowCount: t.rowCount === undefined || t.rowCount === null || t.rowCount?.kind === 'missing' ? null : t.rowCount, curCmd: t.curCmd,
})

// standard result + completion tokens; `redact` applies the capture's own
// redaction to the bitsql side too.
function stepExpect(result, completion, { keys, redact = v => v } = {}) {
  const base = standardExpect(dbScrub(result), keys ? { keys } : {})
  const tokens = completion ? completion.map(tokenView) : null
  const value = tokens ? { result: base.value, completion: tokens } : { result: base.value }
  return customExpect(value, actual => {
    const r = redact(base.project(actual))
    return tokens ? { result: r, completion: (actual.tokens ?? []).map(tokenView) } : { result: r }
  })
}

const casesAdapter = ({ redact, collation } = {}) => doc => doc.cases.map(c => {
  const entries = []
  if (collation) entries.push({ name: `${c.id} database collation`, steps: [{ kind: 'batch', sql: `ALTER DATABASE CURRENT COLLATE ${collation}` }] })
  c.steps.forEach((s, i) => {
    const name = `${c.id} ${i + 1}`
    if (typeof s.sql === 'string') entries.push({ name, steps: [{ kind: 'batch', sql: s.sql, expect: stepExpect(s.result, s.completion, { redact }) }] })
    else if (s.sql && typeof s.sql.sql === 'string') {
      // RPC (sp_executesql): msduck recorded columns {name,type,length}, errors and rowCount only.
      entries.push({ name, steps: [{ kind: 'rpc', sql: s.sql.sql, params: (s.sql.parameters ?? []).map(p => tediousParam(p)), expect: stepExpect(s.result, s.completion, { redact, keys: ['sets', 'errors', 'rowCount'] }) }] })
    } else entries.push({ name, skip: 'unknown step shape' })
  })
  return { id: c.id, entries }
})

// Evaluates the literal top of a msduck capture script (imports stripped,
// cut before its first function) and returns the named bindings.
async function scriptBindings(ctx, script, names) {
  let text = await ctx.scriptText(script)
  const cut = text.search(/\n(?:export )?(?:async )?function |\nif \(/)
  if (cut > 0) text = text.slice(0, cut)
  text = text.replace(/^#!.*$/m, '').replace(/^import .*$/gm, '').replace(/^export /gm, '').replace(/import\.meta\.url/g, '"file:///msduck/scripts/x.mjs"')
  return new Function(`${text}\nreturn { ${names.join(', ')} }`)()
}

const constraintObserve = actual => ({
  errors: actual.errors.map(e => ({ number: e.number, state: e.state, class: e.class, message: e.message })),
  info: actual.info.filter(i => i.number !== 5701 && i.number !== 5703).map(i => ({ number: i.number, message: i.message })),
  sets: actual.sets.map(s => s.rows),
})

const outerKeep = actual => ({
  sets: actual.sets.map(s => ({ columns: s.columns.map(c => [c.name, c.type]), rows: s.rows })),
  errors: actual.errors.map(e => ({ number: e.number, message: e.message })),
  done: actual.done.filter(d => d.kind === 'done' || d.kind === 'doneInProc').map(d => d.rowCount),
})

// gaps-triggers: rows with buffers as '0X…' upper hex, raw DONE bodies.
const triggerValue = v => v && typeof v === 'object' && v.kind === 'binary' ? '0x' + v.value.toUpperCase() : v
const triggerDone = d => ({ kind: d.kind, status: d.status, curCmd: d.curCmd, rowCount: d.status & 0x10 ? d.rowCount : null })
const triggerObserve = actual => ({
  sets: actual.sets.map(s => ({ columns: s.columns.map(c => c.name), rows: s.rows.map(r => r.map(triggerValue)) })),
  errors: actual.errors.map(e => ({ number: e.number, state: e.state, class: e.class, message: e.message })),
  info: actual.info.map(e => ({ number: e.number, state: e.state, class: e.class, message: e.message })),
  done: (actual.tokens ?? []).map(t => triggerDone({ kind: doneKind(t.name), status: doneStatus(t), curCmd: t.curCmd, rowCount: t.rowCount === undefined || t.rowCount?.kind === 'missing' ? '0' : String(t.rowCount) })),
})

const generatedNames = v => replaceIn(v, /\b(PK|UQ|CK|DF)__[^'"\\]*/g, '$1__<generated>')

export default {
  'gaps-computed': casesAdapter(),
  // auto-named constraints/indexes: __<table>__<16 hex> redacted as <hash>
  'gaps-keys': casesAdapter({ redact: v => replaceIn(v, /(__[0-9A-Za-z_]+?__)[0-9A-F]{16}/g, '$1<hash>') }),
  'gaps-rowversion_identity': casesAdapter(),
  // msduck created each database with COLLATE Latin1_General_100_BIN2.
  'gaps-unicode-predicates': casesAdapter({ collation: 'Latin1_General_100_BIN2' }),

  'gaps-bulk': doc => doc.cases.map(c => ({
    id: c.id,
    entries: c.steps.map((s, i) => typeof s.step === 'string'
      ? { name: `${c.id} ${i + 1}`, steps: [{ kind: 'batch', sql: s.step, expect: stepExpect(replaceIn(s.result, /<database>/g, '{db}'), s.result.completion) }] }
      : { name: `${c.id} ${i + 1}`, skip: 'bulk load (BulkLoadBCP)' }),
  })),

  'gaps-constraints': doc => doc.groups.map(g => ({
    id: g.name,
    entries: g.steps.map((s, i) => ({
      name: `${g.name} ${i + 1}`,
      steps: [{ kind: 'batch', sql: s.sql, expect: customExpect(replaceIn(s.result, /\bgaps_constraints\b/g, '{db}'), constraintObserve) }],
    })),
  })),

  'gaps-functions': async (doc, ctx) => {
    const { cases } = await scriptBindings(ctx, 'capture-gaps-functions.mjs', ['cases'])
    return doc.cases.map(c => {
      const source = cases.find(s => s.name === c.name)
      if (!source || source.batches.length !== c.results.length) return { id: c.name, entries: [{ name: c.name, skip: 'batches not recoverable from the capture script' }] }
      return {
        id: c.name,
        entries: source.batches.map((sql, i) => ({ name: `${c.name} ${i + 1}`, steps: [{ kind: 'batch', sql, expect: standardExpect(c.results[i]) }] })),
      }
    })
  },

  // Each case: setup (uncompared), DML, readback — in its own database.
  'gaps-outer_dml': doc => doc.cases.map(c => ({
    id: c.name,
    entries: [{
      name: c.name,
      steps: [
        { kind: 'batch', sql: c.setup },
        { kind: 'batch', sql: c.dml, expect: customExpect(c.result.dml, outerKeep) },
        { kind: 'batch', sql: c.readback, expect: customExpect(c.result.readback, outerKeep) },
      ],
    }],
  })),

  // Sessions B and C are other connections: skipped without poisoning
  // session A's run (verification rejects A probes that observed them).
  'gaps-temp_tables': doc => [{
    id: 'session-a',
    entries: doc.results.map(r => r.session !== 'A'
      ? { name: `${r.session} ${r.name}`, skip: 'other connection (multi-session probe)', stateless: true }
      : {
          name: r.name,
          steps: [{
            kind: r.mode === 'rpc' ? 'rpc' : 'batch', sql: r.sql,
            expect: (() => { const b = standardExpect(r.result); return customExpect(b.value, a => generatedNames(b.project(a))) })(),
          }],
        }),
  }],

  'gaps-triggers': doc => doc.cases.map(c => ({
    id: c.name,
    entries: c.batches.map((b, i) => ({
      name: `${c.name.slice(0, 40)} ${i + 1}`,
      steps: [{
        kind: 'batch', sql: b.sql,
        expect: customExpect({ sets: b.sets, errors: b.errors, info: b.info, done: b.done.map(triggerDone) }, triggerObserve),
      }],
    })),
  })),
}
