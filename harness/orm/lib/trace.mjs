// A Trace records what an ORM workload observes, step by step: the value a
// step returned (normalized), the error it raised (number + message), and the
// SQL the tool logged while the step ran. The oracle trace and the emulator
// trace of the same workload are compared step by step (compare.mjs).

const NOW = Date.now()
const DAY = 24 * 3600 * 1000

// Values that legitimately differ between two runs: clock readings,
// SQL Server generated constraint names, the database name.
export function makeNormalizer(database) {
  const dbRe = new RegExp(database.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi')
  const str = s => s
    .replace(dbRe, '{db}')
    // PK__users__3213E83F0AB1C2D3, DF__users__name__5EBF139D, FK__a__b__0123ABCD
    .replace(/__[0-9A-F]{8}(?:[0-9A-F]{8})?\b/g, '__{hex}')
    // client-side ids: Sequelize transaction ids, knex savepoint names
    .replace(/^Executing \([0-9a-f]{20}\)/, 'Executing ({tx})')
    .replace(/\[trx\d+\]/g, '[trx{n}]')
    .replace(/\[[0-9a-f]{20}-sp-(\d+)\]/g, '[{tx}-sp-$1]')
    // clock values that tools inline into SQL or messages
    .replace(/\b20\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)?/g, m => {
      const t = Date.parse(m.includes('T') || m.endsWith('Z') ? m : m.replace(' ', 'T') + 'Z')
      return Number.isFinite(t) && Math.abs(t - NOW) < 3 * DAY ? '{now}' : m
    })
  const stack = new Set()
  const value = v => {
    if (v && typeof v === 'object') {
      if (stack.has(v) || stack.size > 40) return { kind: 'cycle' }
      stack.add(v)
      try { return inner(v) } finally { stack.delete(v) }
    }
    return inner(v)
  }
  const inner = v => {
    if (v === undefined) return { kind: 'undefined' }
    if (v === null || typeof v === 'boolean') return v
    if (typeof v === 'number') return Number.isNaN(v) ? { kind: 'NaN' } : v
    if (typeof v === 'bigint') return { kind: 'bigint', value: v.toString() }
    if (typeof v === 'string') return str(v)
    if (v instanceof Date) {
      const t = v.getTime()
      if (Number.isNaN(t)) return { kind: 'date', value: 'invalid' }
      return Math.abs(t - NOW) < 3 * DAY ? { kind: 'date', value: '{now}' } : { kind: 'date', value: v.toISOString() }
    }
    if (Buffer.isBuffer(v) || v instanceof Uint8Array) return { kind: 'binary', hex: Buffer.from(v).toString('hex') }
    if (Array.isArray(v)) return v.map(value)
    if (typeof v === 'object') {
      if (typeof v.toJSON === 'function' && v.constructor?.name === 'Decimal') return { kind: 'decimal', value: v.toString() }
      const out = {}
      for (const k of Object.keys(v)) {
        if (typeof v[k] === 'function') continue
        out[str(k)] = value(v[k])
      }
      return out
    }
    return String(v)
  }
  return { value, str }
}

// Error number/message, wherever the ORM keeps the driver error.
export function errorInfo(error, norm) {
  const seen = new Set()
  const candidates = []
  const visit = (e, depth) => {
    if (!e || typeof e !== 'object' || seen.has(e) || depth > 6) return
    seen.add(e)
    candidates.push(e)
    for (const k of ['original', 'parent', 'driverError', 'originalError', 'cause', 'precedingErrors', 'errors', 'info', 'meta', 'driverAdapterError']) {
      const v = e[k]
      if (Array.isArray(v)) v.forEach(x => visit(x, depth + 1))
      else visit(v, depth + 1)
    }
  }
  visit(error, 0)
  const numbers = []
  for (const c of candidates) {
    const n = c.number ?? c.originalCode
    if (n !== undefined && n !== null && Number.isFinite(Number(n)) && !numbers.includes(Number(n))) numbers.push(Number(n))
  }
  const sqlMessage = candidates.find(c => c.number !== undefined && typeof c.message === 'string')?.message
    ?? candidates.find(c => typeof c.originalMessage === 'string')?.originalMessage
  return {
    type: error?.constructor?.name ?? typeof error,
    ...(error?.code !== undefined && typeof error.code === 'string' && /^P\d{4}$/.test(error.code) ? { code: error.code } : {}),
    numbers,
    message: norm.str(String(sqlMessage ?? error?.message ?? error)).split('\n')[0].slice(0, 400),
  }
}

function pickLine(text, last) {
  const lines = text.split('\n').map(l => l.trim()).filter(Boolean)
  return (last ? lines.at(-1) : lines[0]) ?? ''
}

export class Trace {
  constructor({ target, database }) {
    this.target = target
    this.database = database
    this.norm = makeNormalizer(database)
    this.steps = []
    this.sqlLog = []
  }

  // Tools call this from their query loggers.
  logSql(sql) {
    if (typeof sql !== 'string') sql = JSON.stringify(sql)
    this.sqlLog.push(this.norm.str(sql.replace(/\s+/g, ' ').trim()))
  }

  // Runs one observable step. `fn` returns what the application would see.
  // Options: { sql: false } to skip SQL comparison for this step.
  async step(name, fn, options = {}) {
    const start = this.sqlLog.length
    if (process.env.ORM_PROGRESS) process.stderr.write(`[${this.target}] ${name}\n`)
    const record = { name }
    try {
      const v = await fn()
      record.value = this.norm.value(v)
    } catch (error) {
      record.error = errorInfo(error, this.norm)
      if (process.env.ORM_DEBUG) console.error(`[${this.target}] ${name}:`, error)
    }
    if (process.env.ORM_PROGRESS) process.stderr.write(`[${this.target}]   ${record.error ? 'error ' + JSON.stringify(record.error).slice(0, 300) : 'ok'}\n`)
    // Let loggers that fire after the promise resolves catch up.
    await new Promise(r => setImmediate(r))
    record.sql = options.sql === false ? null : this.sqlLog.slice(start)
    this.steps.push(record)
    return record
  }
}
