// msduck layout adapters: gaps-a group (see project.mjs for the Run/Entry shape).
// Keys are msduck reference file base names; values (doc, ctx) => Run[].
//
// gaps-applock, gaps-json_string, gaps-rpc-procedures, gaps-procedures,
// gaps-catalog, gaps-merge, gaps-backup, gaps-identifiers, gaps-conversion.
// Each capture script recorded its own result shape; the projections below
// turn a bitsql capture into that shape (fields bitsql does not observe,
// e.g. procName or raw COLMETADATA/RETURNVALUE bytes, are dropped from the
// expectation instead).
import vm from 'node:vm'
import { customExpect, doneStatus, scrub, standardExpect } from './project.mjs'

// Evaluates the literal section of an msduck capture script between two
// markers (inclusive start, exclusive end) and returns the named bindings.
function scriptSection(text, start, end, names) {
  const from = text.indexOf(start)
  const to = text.indexOf(end, from + start.length)
  if (from < 0 || to < 0) throw new Error(`script section ${JSON.stringify(start)}..${JSON.stringify(end)} not found`)
  return vm.runInNewContext(`${text.slice(from, to)}\n;({${names.join(',')}})`, {})
}

const DONE_KIND = { DONE: 'done', DONEPROC: 'doneProc', DONEINPROC: 'doneInProc' }
const DONE_BYTE = { DONE: 0xfd, DONEPROC: 0xfe, DONEINPROC: 0xff }
const ENV_TYPE = { DATABASE: 1, LANGUAGE: 2, CHARSET: 3, PACKET_SIZE: 4, SQL_COLLATION: 7, BEGIN_TXN: 8, COMMIT_TXN: 9, ROLLBACK_TXN: 10, DATABASE_MIRRORING_PARTNER: 13, TXN_ENDED: 17, RESET_CONNECTION: 18, ROUTING_CHANGE: 20 }
// Database names the capture scripts bound to a placeholder or fixed name.
const dbScrub = v => JSON.parse(JSON.stringify(scrub(v)).replace(/<database>|<db>|msduck_catalog_reference/g, '{db}'))
// tedious exposes a DONE row count only when DONE_COUNT (0x10) is set, but
// SQL Server also leaves the uncounted value in the token (e.g. 1 under
// NOCOUNT). Expectations zero uncounted row counts so they stay comparable.
const uncounted = status => !(status & 0x10)
function zeroUncounted(t) {
  if (Array.isArray(t)) return t[0]?.startsWith?.('done') && uncounted(t[1]) ? [t[0], t[1], t[2], 0] : t
  if (t && typeof t === 'object' && typeof t.status === 'number' && t.rowCount !== undefined && uncounted(t.status)) return { ...t, rowCount: typeof t.rowCount === 'string' ? '0' : 0 }
  if (t && typeof t === 'object' && typeof t.hex === 'string' && /^(done|doneProc|doneInProc)$/.test(t.token)) {
    const b = Buffer.from(t.hex, 'hex')
    if (uncounted(b.readUInt16LE(1))) b.fill(0, 5)
    return { ...t, hex: b.toString('hex') }
  }
  return t
}
const rowCountOf = t => (typeof t.rowCount === 'number' ? t.rowCount : 0)

// The bitsql stream with DONE-family entries joined to their `tokens`
// record (raw row count) and messages joined to their errors/info entries.
function joinedStream(actual) {
  const dones = [...(actual.tokens ?? [])]
  const errors = [...(actual.errors ?? [])]
  const info = [...(actual.info ?? [])]
  return (actual.stream ?? []).map(entry => {
    if (DONE_KIND[entry.name]) { const t = dones.shift() ?? {}; return { ...entry, rowCount: rowCountOf(t), status: doneStatus(t) } }
    if (entry.name === 'ERROR') return { ...entry, message: errors.shift() }
    if (entry.name === 'INFO') return { ...entry, message: info.shift() }
    return entry
  })
}
const doneHex = e => {
  const b = Buffer.alloc(13)
  b[0] = DONE_BYTE[e.name]; b.writeUInt16LE(e.status, 1); b.writeUInt16LE(e.curCmd ?? 0, 3); b.writeBigUInt64LE(BigInt(e.rowCount), 5)
  return b.toString('hex')
}
const statusHex = value => { const b = Buffer.alloc(5); b[0] = 0x79; b.writeInt32LE(value, 1); return b.toString('hex') }
const unwrap = v => v && typeof v === 'object' && !Array.isArray(v) && v.kind
  ? (v.kind === 'binary' ? `0x${v.value}` : v.kind === 'missing' ? undefined : v.value)
  : v

// Raw DONE bodies {kind, status, curCmd, rowCount: string} (merge, backup).
const rawDone = actual => joinedStream(actual).filter(e => DONE_KIND[e.name]).map(e => ({ kind: DONE_KIND[e.name], status: e.status, curCmd: e.curCmd, rowCount: String(e.rowCount) }))
const messageOf = m => ({ number: m.number, state: m.state, class: m.class, message: m.message })
// errors/info/done/sets in the shape of a run() that records raw DONE bodies.
function rawDoneExpect(result, { message = x => x, rowValue = x => x } = {}) {
  const value = dbScrub(result)
  delete value.transport
  if (value.done) value.done = value.done.map(zeroUncounted)
  const keys = Object.keys(value)
  return customExpect(value, actual => {
    const out = {}
    if (keys.includes('sets')) out.sets = actual.sets.map((s, i) => ({
      columns: s.columns.map(c => Object.fromEntries(Object.keys(value.sets[i]?.columns?.[0] ?? { name: 1, type: 1 }).map(k => [k, c[k]]))),
      rows: s.rows.map(r => r.map(rowValue)),
    }))
    if (keys.includes('done')) out.done = rawDone(actual)
    if (keys.includes('errors')) out.errors = actual.errors.map(e => ({ ...messageOf(e), message: message(e.message) }))
    if (keys.includes('info')) out.info = actual.info.map(e => ({ ...messageOf(e), message: message(e.message) }))
    return out
  })
}

// gaps-procedures / gaps-rpc-procedures token records.
function procTokens(actual, { hex }) {
  const out = []
  for (const e of joinedStream(actual)) {
    if (DONE_KIND[e.name]) out.push(hex ? { token: DONE_KIND[e.name], hex: doneHex(e) } : { token: DONE_KIND[e.name], status: e.status, curCmd: e.curCmd, rowCount: String(e.rowCount) })
    else if (e.name === 'RETURNSTATUS') out.push(hex ? { token: 'returnStatus', hex: statusHex(e.value) } : { token: 'returnStatus', value: e.value })
    else if (e.name === 'ROW' || e.name === 'NBCROW') {
      if (!hex) continue
      if (out.at(-1)?.token === 'row') out.at(-1).count += e.count
      else out.push({ token: 'row', count: e.count })
    } else if (e.name === 'ENVCHANGE') out.push(hex ? { token: 'envChange', type: ENV_TYPE[e.type] ?? e.type } : { token: 'envChange' })
    else out.push({ token: { RETURNVALUE: 'returnValue', ERROR: 'error', INFO: 'info', COLMETADATA: 'columns', ORDER: 'order' }[e.name] ?? e.name })
  }
  return out
}
function procExpect(result, { hex, message = x => x }) {
  const value = dbScrub(result)
  delete value.transport
  for (const key of ['errors', 'info']) value[key] = (value[key] ?? []).map(m => { const { procName, lineNumber, ...rest } = m; return rest })
  // Only bytes bitsql can reproduce: DONE-family and RETURNSTATUS bodies.
  value.tokens = (value.tokens ?? []).map(zeroUncounted).map(t => (t.hex && !['done', 'doneProc', 'doneInProc', 'returnStatus'].includes(t.token)) ? { token: t.token } : t)
  value.returnValues = (value.returnValues ?? []).map(v => ({ ...v, value: unwrap(v.value) }))
  return customExpect(value, actual => ({
    sets: actual.sets.map(s => ({ columns: s.columns.map(c => ({ name: c.name, type: c.type })), rows: s.rows })),
    errors: actual.errors.map(e => ({ ...messageOf(e), message: message(e.message) })),
    info: actual.info.map(e => ({ ...messageOf(e), message: message(e.message) })),
    returnValues: (actual.outputs ?? []).map(o => Object.fromEntries(Object.keys(value.returnValues[0] ?? { name: 1, value: 1 }).map(k => [k, k === 'value' ? unwrap(o.value) : o[k]]))),
    tokens: procTokens(actual, { hex }),
  }))
}

const tediousParam = ([name, type, value, output, options]) => {
  let t = String(type).toLowerCase()
  if (options?.length !== undefined) t += `(${options.length})`
  else if (options?.precision !== undefined) t += `(${options.precision},${options.scale ?? 0})`
  else if (options?.scale !== undefined) t += `(${options.scale})`
  return { name, type: t, value, ...(output ? { output: true } : {}) }
}

export default {
  // One connection in a fresh database. Only the single-session `batches`
  // (SQL reconstructed from the script) are sequential; everything after
  // them uses two or three connections (blocking, waits, deadlocks).
  'gaps-applock': async (doc, { scriptText, skip }) => {
    const text = await scriptText('capture-gaps-applock.mjs')
    const { batches } = scriptSection(text, 'const get = ', 'async function observe', ['batches'])
    const sql = new Map(batches)
    const entries = []
    let single = true
    for (const o of doc.runs[0]) {
      if (single && !sql.has(o.name)) single = false
      if (!single) { entries.push({ name: o.name, skip: 'multi-connection (blocking, waits, deadlocks)' }); continue }
      const value = scrub({ sets: o.sets, messages: o.messages.map(({ procName, ...m }) => m), tokens: o.tokens.map(zeroUncounted) })
      entries.push({ name: o.name, steps: [{ kind: 'batch', sql: sql.get(o.name), expect: customExpect(value, actual => {
        const messages = []
        const tokens = []
        for (const e of joinedStream(actual)) {
          if (DONE_KIND[e.name]) tokens.push([DONE_KIND[e.name], e.status, e.curCmd, e.rowCount])
          else if (e.name === 'RETURNSTATUS') tokens.push(['returnStatus', e.value])
          else if (e.name === 'ERROR' || e.name === 'INFO') {
            tokens.push([e.name.toLowerCase()])
            messages.push({ kind: e.name.toLowerCase(), number: e.message?.number, state: e.message?.state, class: e.message?.class, lineNumber: e.message?.lineNumber, message: e.message?.message })
          } else if (e.name === 'COLMETADATA') tokens.push(['metadata'])
          else if (e.name === 'ROW') for (let i = 0; i < e.count; i++) tokens.push(['row'])
        }
        return {
          sets: actual.sets.map(s => ({ columns: s.columns.map(c => ({ name: c.name, type: c.type, length: c.length, nullable: (c.flags & 1) === 1 })), rows: s.rows.map(r => r.map(unwrap)) })),
          messages, tokens,
        }
      }) }] })
    }
    return [{ id: 'session', entries }]
  },

  // Two setup batches (not retained in the fixture; from the script), then
  // self-contained batches: every entry replays the setup on its own.
  'gaps-json_string': async (doc, { scriptText }) => {
    const text = await scriptText('capture-gaps-json_string.mjs')
    const { setup } = scriptSection(text, 'const setup = [', 'const batches = [', ['setup'])
    return [{
      id: 'batches', independent: true,
      entries: doc.runs[0].map(o => ({
        name: o.name,
        steps: [
          ...setup.map(sql => ({ kind: 'batch', sql })),
          { kind: 'batch', sql: o.sql, expect: customExpect({ sets: o.sets, messages: o.messages }, actual => ({
            sets: actual.sets.map(s => ({ columns: s.columns.map(c => ({ name: c.name, type: c.type, length: c.length, nullable: (c.flags & 1) === 1 })), rows: s.rows.map(r => r.map(unwrap)) })),
            messages: actual.errors.map(messageOf),
          })) },
        ],
      })),
    }]
  },

  // One connection: CREATE DATABASE probe_rpc + USE, then sequential
  // requests (batch / sp_executesql / callProcedure). The case database
  // replaces probe_rpc; the three-part name call cannot be expressed.
  'gaps-rpc-procedures': doc => [{
    id: 'session',
    entries: doc.runs[0].map(o => {
      if (o.name === 'server version') return { name: o.name, skip: 'server version probe', stateless: true }
      if (o.name === 'create database' || o.name === 'use database') return { name: o.name, skip: 'fixed database (the case database replaces it)', stateless: true }
      if (/probe_rpc/.test(o.text)) return { name: o.name, skip: 'names the fixed capture database', stateless: true }
      const kind = { batch: 'batch', sql: 'rpc', proc: 'proc' }[o.kind]
      return { name: o.name, steps: [{ kind, sql: o.text, ...(o.parameters ? { params: o.parameters.map(tediousParam) } : {}), expect: procExpect(o.result, { hex: true }) }] }
    }),
  }],

  // Same structure with batches and sp_executesql RPCs (entries with
  // parameters). Messages had generated PK names replaced.
  'gaps-procedures': doc => {
    const pk = text => typeof text === 'string' ? text.replace(/PK__\w+/g, 'PK__<generated>') : text
    return [{
      id: 'session',
      entries: doc.runs[0].map(o => {
        if (o.name === 'server version') return { name: o.name, skip: 'server version probe', stateless: true }
        if (o.name === 'create database' || o.name === 'use database') return { name: o.name, skip: 'fixed database (the case database replaces it)', stateless: true }
        if (/probe_procedures/.test(o.sql)) return { name: o.name, skip: 'names the fixed capture database', stateless: true }
        const params = o.parameters?.map(p => tediousParam([p.name, p.type, p.value, p.output]))
        return { name: o.name, steps: [{ kind: params ? 'rpc' : 'batch', sql: o.sql, ...(params ? { params } : {}), expect: procExpect(o.result, { hex: false, message: pk }) }] }
      }),
    }]
  },

  // Four profiles, each one connection in its own fresh database
  // (msduck_catalog_reference): the main catalog run, definitions,
  // namespace and catalog v2. Results are the standard capture plus
  // userType per column (not recorded by bitsql; dropped).
  'gaps-catalog': doc => {
    const profiles = [['catalog', doc.runs], ['definitions', doc.definitionProfile?.runs], ['namespace', doc.namespaceProfile?.runs], ['v2', doc.catalogV2Profile?.runs]]
    return profiles.filter(([, runs]) => runs?.[0]).map(([id, runs]) => ({
      id,
      entries: runs[0].map(o => {
        if (o.name === 'version') return { name: `${id} ${o.name}`, skip: 'server version probe', stateless: true }
        const result = JSON.parse(JSON.stringify(o.result).replaceAll('msduck_catalog_reference', '{db}'))
        for (const set of result.sets ?? []) for (const c of set.columns) delete c.userType
        return { name: `${id} ${o.name}`, steps: [{ kind: 'batch', sql: o.sql, expect: standardExpect(result) }] }
      }),
    }))
  },

  // One connection in a fresh database; raw DONE bodies, no line numbers.
  'gaps-merge': doc => [{
    id: 'session',
    entries: doc.runs[0].map(o => o.name === 'server version'
      ? { name: o.name, skip: 'server version probe', stateless: true }
      : { name: o.name, steps: [{ kind: 'batch', sql: o.sql, expect: rawDoneExpect(o.result) }] }),
  }],

  // BACKUP/RESTORE creates server-level databases (foo, bar, foo_copy),
  // writes /tmp/*.bak and drops msdb on a shared server: only the entries
  // that fail without touching server state run (independently).
  'gaps-backup': doc => {
    const safe = new Set(['restore missing file', 'headeronly missing file', 'backup unknown database', 'backup unknown option', 'msdb identity'])
    const message = text => text
      .replace(/Processed \d+ pages/, 'Processed <n> pages')
      .replace(/processed \d+ pages in [\d.]+ seconds \([\d.]+ MB\/sec\)/, 'processed <n> pages in <t> seconds (<r> MB/sec)')
    return [{
      id: 'safe', independent: true,
      entries: doc.observations.map(o => safe.has(o.name)
        ? { name: o.name, steps: [{ kind: 'batch', sql: o.sql, expect: rawDoneExpect({ ...o.result, info: undefined }, { message }) }] }
        : { name: o.name, skip: 'server-level state (backup files, databases, msdb)', stateless: true }),
    }]
  },

  // One fresh database; per word 16 sequential statements followed by a
  // cleanup, then the diagnostics run. Results: {errors, sets:[{columns:
  // [names], rows}]} with the database name replaced by <db>.
  'gaps-identifiers': async (doc, { scriptText }) => {
    const text = await scriptText('capture-gaps-identifiers.mjs')
    const { cases, diagnostics } = scriptSection(text, 'function cases(word)', 'async function run(', ['cases', 'diagnostics'])
    const expect = result => customExpect(JSON.parse(JSON.stringify(result).replaceAll('<db>', '{db}')), actual => ({
      errors: actual.errors.map(messageOf),
      sets: actual.sets.map(s => ({ columns: s.columns.map(c => c.name), rows: s.rows.map(r => r.map(unwrap)) })),
    }))
    const runs = Object.entries(doc.observations.identifiers).map(([word, results]) => ({
      id: `word-${word}`,
      entries: cases(word).map(([id, sql]) => results[id]
        ? { name: `${word} ${id}`, steps: [{ kind: 'batch', sql, expect: expect(results[id]) }] }
        : { name: `${word} ${id}`, skip: 'missing observation' }),
    }))
    runs.push({
      id: 'diagnostics',
      entries: diagnostics.map(([id, sql]) => ({ name: `diagnostics ${id}`, steps: [{ kind: 'batch', sql, expect: expect(doc.observations.errors[id]) }] })),
    })
    return runs
  },

  // One fresh database, self-contained batches (sets without flags, errors
  // without line numbers). Captured on 16.0.4236.2.
  'gaps-conversion': doc => [{
    id: 'cases', independent: true,
    entries: doc.cases.map(c => ({ name: `${c.group} ${c.name}`, steps: [{ kind: 'batch', sql: c.sql, expect: standardExpect({ sets: c.sets, errors: c.errors }) }] })),
  }],
}
