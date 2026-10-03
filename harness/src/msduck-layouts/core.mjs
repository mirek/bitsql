// msduck layout adapters: `run` layouts (gaps-transactions, savepoint).
import { standardExpect, tediousParam } from './project.mjs'

export default {
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
      if (e.kind === 'batch') entries.push({ name, steps: [{ kind: 'batch', sql: e.sql, expect: standardExpect(e.result) }] })
      else if (e.kind === 'rpc') entries.push({ name, steps: [{ kind: 'rpc', sql: e.sql, params: e.parameters.map(p => tediousParam(p)), expect: standardExpect(e.result) }] })
      else if (e.kind === 'procedure') entries.push({ name, steps: [{ kind: 'proc', sql: e.procedure, params: e.parameters.map(p => tediousParam(p)), expect: standardExpect(e.result) }] })
      else if (e.kind === 'transaction-manager') entries.push({ name, skip: 'transaction manager request' })
      else if (e.kind === 'prepared') entries.push({ name, skip: 'prepared protocol (sp_prepare/sp_execute)' })
      else entries.push({ name, skip: `unknown kind ${e.kind}` })
    }
    return [...runs.values()]
  },
}
