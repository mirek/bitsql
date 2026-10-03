// Corpus loading. Two authoring formats, both under harness/corpus/**:
//
// 1. `name.sql` (hand-written cases). Directives are whole-line comments:
//      -- @step batch          SQL batch (the default when no @step precedes text)
//      -- @step setup          SQL batch whose capture is not compared
//      -- @step rpc            tedious execSql: RPC sp_executesql
//      -- @step proc dbo.p     tedious callProcedure (RPC by procedure name)
//      -- @param @a int = 1    parameter for the current rpc/proc step;
//      -- @param @o int output   value is a JSON literal; `output` marks OUTPUT
//    Multi-connection cases (locking, deadlocks): any step may take
//    `conn=N` (connection N, opened on first use; default 1) and `async`
//    (send it and continue without waiting for the response; the runner
//    pauses briefly so the server starts executing it). `-- @step await
//    conn=N` waits for connection N's pending async step; its result is
//    recorded at the async step's position. Pending steps are also awaited
//    before the connection's next step and at the end of the case.
//    Expected output: sibling `name.expected.json` (captured, never hand-written).
//
// 2. `name.cases.json` (generated, e.g. msduck imports): many cases per file,
//      { "source": "...", "cases": [{ "name", "steps": [{kind, sql, params?, compare?}] }] }
//    Expected output: sibling `name.expected.json` = { server, cases: { <name>: expected } }.
//
// A loaded case is { id, file, expectedFile, key, steps, source? } where `key`
// is the case name inside a multi-case file (null for .sql cases).
import { createHash } from 'node:crypto'
import { readFile, readdir, stat } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'
import { corpusDir } from './env.mjs'

export function parseSqlCase(text) {
  const steps = []
  let current = null
  let lines = text.replace(/\r\n/g, '\n').split('\n')
  // The leading comment block is the case description; it is never sent.
  const body = lines.findIndex(l => !(l.trim() === '' || (/^\s*--/.test(l) && !/^\s*--\s*@/.test(l))))
  lines = body < 0 ? [] : lines.slice(body)
  const open = (kind, rest) => {
    const words = rest.split(/\s+/).filter(Boolean)
    let arg = ''
    const extra = {}
    for (const w of words) {
      const conn = /^conn=(\d+)$/i.exec(w)
      if (conn) extra.conn = Number(conn[1])
      else if (/^async$/i.test(w)) extra.async = true
      else if (!arg) arg = w
      else throw new Error(`bad @step argument: ${w}`)
    }
    if (kind === 'await') {
      if (!extra.conn) throw new Error('@step await needs conn=N')
      steps.push({ kind: 'await', sql: '', compare: false, conn: extra.conn })
      current = null
      return
    }
    current = { kind: kind === 'setup' ? 'batch' : kind, sql: '', params: [], compare: kind !== 'setup', lines: [], ...extra }
    if (kind === 'proc') { if (!arg) throw new Error('@step proc needs a procedure name'); current.sql = arg }
    else if (arg) throw new Error(`bad @step argument: ${arg}`)
    steps.push(current)
  }
  for (const line of lines) {
    const step = /^\s*--\s*@step\s+(batch|setup|rpc|proc|await)\b(.*)$/i.exec(line)
    if (step) { open(step[1].toLowerCase(), step[2]); continue }
    if (/^\s*--\s*@step\b/i.test(line)) throw new Error(`bad directive: ${line}`)
    const param = /^\s*--\s*@param\s+@?([A-Za-z_][\w]*)\s+([a-z_0-9]+(?:\s*\([^)]*\))?)\s*(?:=\s*(.*?))?\s*(\boutput\b)?\s*$/i.exec(line)
    if (param) {
      if (!current || current.kind === 'batch') throw new Error(`@param outside an rpc/proc step: ${line}`)
      const value = param[3] === undefined || param[3] === '' ? null : JSON.parse(param[3])
      current.params.push({ name: param[1], type: param[2].replace(/\s+/g, ''), value, ...(param[4] ? { output: true } : {}) })
      continue
    }
    if (/^\s*--\s*@param\b/i.test(line)) throw new Error(`bad directive: ${line}`)
    if (!current) { if (line.trim() === '') continue; open('batch', '') }
    current.lines.push(line)
  }
  for (const step of steps) {
    if (step.kind === 'await') continue
    const body = step.lines
    while (body.length && body[0].trim() === '') body.shift()
    while (body.length && body.at(-1).trim() === '') body.pop()
    if (step.kind !== 'proc') step.sql = body.join('\n')
    else if (body.some(l => l.trim() && !/^\s*--/.test(l))) throw new Error('@step proc takes no SQL body')
    delete step.lines
    if (!step.params.length) delete step.params
    if (step.kind !== 'proc' && !step.sql.trim()) throw new Error('empty step')
  }
  if (!steps.length) throw new Error('case has no steps')
  return steps
}

// Stable hash of what is executed; expectations record it so edits after a
// capture show up as `stale`.
export function caseHash(steps) {
  const normal = steps.map(s => ({ kind: s.kind, sql: s.sql, params: s.params ?? [], compare: s.compare !== false }))
  return createHash('sha256').update(JSON.stringify(normal)).digest('hex').slice(0, 16)
}

async function walk(dir) {
  const out = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...await walk(path))
    else if (entry.name.endsWith('.sql') || entry.name.endsWith('.cases.json')) out.push(path)
  }
  return out.sort()
}

// selectors: corpus-relative paths or prefixes (`smoke`, `traps/collation.sql`,
// `msduck/raiserror-rpc.cases.json#003-name`); empty means everything.
export async function loadCorpus(selectors = []) {
  const files = await walk(corpusDir)
  const cases = []
  const normalized = selectors.map(s => {
    const [path, key] = s.split('#')
    const abs = resolve(process.cwd(), path)
    const rel = abs.startsWith(corpusDir) ? relative(corpusDir, abs) : path.replace(/^corpus\//, '')
    return { rel: rel.replace(/\/$/, ''), key }
  })
  const wanted = (rel, key) => !normalized.length || normalized.some(s =>
    (rel === s.rel || rel.startsWith(s.rel + '/') || s.rel === '' || s.rel === '.') && (!s.key || s.key === key))
  for (const file of files) {
    const rel = relative(corpusDir, file)
    if (!normalized.some(s => s.rel === '' || s.rel === '.' || rel === s.rel || rel.startsWith(s.rel + '/')) && normalized.length) continue
    if (file.endsWith('.sql')) {
      const expectedFile = file.replace(/\.sql$/, '.expected.json')
      let steps
      try { steps = parseSqlCase(await readFile(file, 'utf8')) }
      catch (error) { throw new Error(`${rel}: ${error.message}`) }
      if (wanted(rel, null)) cases.push({ id: rel.replace(/\.sql$/, ''), file, expectedFile, key: null, steps })
    } else {
      const expectedFile = file.replace(/\.cases\.json$/, '.expected.json')
      const doc = JSON.parse(await readFile(file, 'utf8'))
      for (const c of doc.cases) {
        if (!wanted(rel, c.name)) continue
        cases.push({ id: `${rel.replace(/\.cases\.json$/, '')}#${c.name}`, file, expectedFile, key: c.name, steps: c.steps, source: doc.source })
      }
    }
  }
  return cases
}

const expectedCache = new Map()
export async function readExpected(testCase) {
  let doc = expectedCache.get(testCase.expectedFile)
  if (doc === undefined) {
    try { doc = JSON.parse(await readFile(testCase.expectedFile, 'utf8')) }
    catch (error) { if (error.code !== 'ENOENT') throw error; doc = null }
    expectedCache.set(testCase.expectedFile, doc)
  }
  if (!doc) return null
  return testCase.key === null ? doc : doc.cases?.[testCase.key] ?? null
}

export async function exists(path) {
  try { await stat(path); return true } catch { return false }
}
