// bitsql container vs the real SQL Server container, side by side: image
// size, cold start to first query, memory, CPU, connect/round-trip latency,
// a test-suite-like workload and the query shapes of bench.mjs. The numbers
// in README.md come from this script. Not part of `npm test`.
//
//   npm run bench:compare                          # both targets
//   npm run bench:compare -- --only bitsql         # one target (bitsql|mssql)
//   npm run bench:compare -- --starts 5 --rows 20000 --json out/bench.json
//   BITSQL_IMAGE=bitsql:dev npm run bench:compare  # a locally built image
//
// Containers: bitsql-bench-bitsql (127.0.0.1:47340) and bitsql-bench-mssql
// (127.0.0.1:47341), removed at the end. Both run with default settings, as a
// CI service would. Memory comes from the container's cgroup (cgroup v2):
// "used" is memory.current minus inactive file cache (what `docker stats`
// shows), "peak" is memory.peak.
import { execFile } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { promisify } from 'node:util'
import { setTimeout as delay } from 'node:timers/promises'
import { resolve } from 'node:path'
import { repoDir, parseArgs } from '../src/env.mjs'
import { connect, close, tediousConfig, withDatabase } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { oracleImage } from '../src/oracle.mjs'
import { queries, setupSql } from './shapes.mjs'

const exec = promisify(execFile)
const docker = async (...args) => (await exec('docker', args, { maxBuffer: 16 * 1024 * 1024 })).stdout.trim()

const { flags } = parseArgs(process.argv.slice(2))
const starts = Number(flags.starts ?? 3)
const rows = Number(flags.rows ?? 20000)
const version = readFileSync(resolve(repoDir, 'moon.mod'), 'utf8').match(/^version = "(.*)"/m)[1]
const password = 'Bench!9bitsql-compare'
const targets = [
  { key: 'bitsql', image: process.env.BITSQL_IMAGE ?? `mirek/bitsql:${version}`, port: 47340, env: [] },
  { key: 'mssql', image: process.env.MSSQL_IMAGE ?? oracleImage, port: 47341,
    env: ['ACCEPT_EULA=Y', 'MSSQL_PID=Developer', `MSSQL_SA_PASSWORD=${password}`] },
].filter(t => !flags.only || t.key === flags.only)

const median = xs => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]
const mib = bytes => bytes / 1048576

function cgroup(id) {
  const dir = `/sys/fs/cgroup/system.slice/docker-${id}.scope`
  const read = f => readFileSync(`${dir}/${f}`, 'utf8')
  const stat = Object.fromEntries(read('memory.stat').trim().split('\n').map(l => l.split(' ')).map(([k, v]) => [k, Number(v)]))
  const cpu = Object.fromEntries(read('cpu.stat').trim().split('\n').map(l => l.split(' ')).map(([k, v]) => [k, Number(v)]))
  return { used: Number(read('memory.current')) - stat.inactive_file, peak: Number(read('memory.peak')), cpuMs: cpu.usage_usec / 1000 }
}

// Compressed layer bytes a `docker pull` downloads for this host's
// architecture (registry manifest); null for an image only built locally.
async function downloadBytes(image) {
  const arch = { x64: 'amd64', arm64: 'arm64' }[process.arch]
  try {
    const parsed = JSON.parse(await docker('manifest', 'inspect', '--verbose', image))
    const entry = [parsed].flat().find(m => !m.Descriptor.platform || m.Descriptor.platform.architecture === arch)
    return (entry.SchemaV2Manifest ?? entry.OCIManifest).layers.reduce((n, l) => n + l.size, 0)
  } catch { return null }
}

async function exact(connection, sql, params) {
  const r = await capture(connection, { kind: params ? 'rpc' : 'batch', sql, params }, { rowLimit: 10 })
  if (r.errors.length) throw new Error(`${sql.slice(0, 60)}: ${r.errors[0].message}`)
  return r
}

async function timed(fn) {
  const started = performance.now()
  await fn()
  return performance.now() - started
}

// docker run → the first `SELECT 1` that succeeds over a fresh login.
async function coldStart(target, name, config) {
  await docker('rm', '--force', name).catch(() => {})
  const started = performance.now()
  const id = await docker('run', '--detach', '--name', name, ...target.env.flatMap(e => ['--env', e]),
    '--publish', `127.0.0.1:${target.port}:1433`, target.image)
  const deadline = Date.now() + 300000
  while (true) {
    try {
      const connection = await connect({ ...config, options: { ...config.options, connectTimeout: 2000 } })
      try { await exact(connection, 'SELECT 1') } finally { await close(connection) }
      return { id, ms: performance.now() - started }
    } catch (error) {
      if (Date.now() > deadline) throw new Error(`${target.key} not ready: ${error.message}`)
      await delay(20)
    }
  }
}

async function measure(target) {
  const name = `bitsql-bench-${target.key}`
  const log = text => process.stderr.write(`[${target.key}] ${text}\n`)
  const config = tediousConfig({ host: '127.0.0.1', port: target.port, password, requestTimeout: 600000 })
  const out = { target: target.key, image: target.image }
  try {
    out.imageBytes = Number(await docker('image', 'inspect', '--format', '{{.Size}}', target.image).catch(async () => {
      log(`pulling ${target.image}`)
      await docker('pull', target.image)
      return docker('image', 'inspect', '--format', '{{.Size}}', target.image)
    }))
    out.downloadBytes = await downloadBytes(target.image)
    const startMs = []
    let id
    for (let i = 0; i < starts; i++) {
      const s = await coldStart(target, name, config)
      startMs.push(s.ms)
      id = s.id
      log(`cold start ${i + 1}/${starts}: ${s.ms.toFixed(0)} ms`)
    }
    out.coldStartMs = median(startMs)
    out.coldStartRuns = startMs
    out.readyCpuMs = cgroup(id).cpuMs
    await delay(5000)
    out.idle = cgroup(id)

    const loginMs = []
    for (let i = 0; i < 50; i++) loginMs.push(await timed(async () => close(await connect(config))))
    out.loginMs = median(loginMs)

    await (async () => {
      const master = await connect(config)
      try { await exact(master, 'CREATE DATABASE bench') } finally { await close(master) }
    })()
    const connection = await connect(withDatabase(config, 'bench'))
    try {
      const rtt = []
      for (let i = 0; i < 1000; i++) rtt.push(await timed(() => exact(connection, 'SELECT 1')))
      out.selectOneMs = median(rtt)

      // An integration test suite in miniature: schema, parameterized seed,
      // point reads, small transactions, a fresh schema per test.
      const schema = `
        DROP TABLE IF EXISTS orders; DROP TABLE IF EXISTS customers;
        CREATE TABLE customers (id int IDENTITY PRIMARY KEY, email nvarchar(200) NOT NULL UNIQUE, name nvarchar(100), balance decimal(12, 2) NOT NULL DEFAULT 0, created datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
        CREATE TABLE orders (id int IDENTITY PRIMARY KEY, customer_id int NOT NULL REFERENCES customers (id), total decimal(12, 2) NOT NULL, status varchar(20) NOT NULL);
        CREATE INDEX ix_orders_customer ON orders (customer_id);`
      const resetMs = []
      for (let i = 0; i < 20; i++) resetMs.push(await timed(() => exact(connection, schema)))
      out.schemaResetMs = median(resetMs)

      const insert = 'INSERT customers (email, name) OUTPUT INSERTED.id VALUES (@email, @name)'
      out.insertsMs = await timed(async () => {
        for (let i = 0; i < 1000; i++) await exact(connection, insert, [{ name: '@email', type: 'nvarchar(200)', value: `user${i}@example.com` }, { name: '@name', type: 'nvarchar(100)', value: `User ${i}` }])
      })
      out.pointReadsMs = await timed(async () => {
        for (let i = 0; i < 1000; i++) await exact(connection, 'SELECT id, email, name, balance FROM customers WHERE id = @id', [{ name: '@id', type: 'int', value: 1 + (i * 7) % 1000 }])
      })
      out.transactionsMs = await timed(async () => {
        for (let i = 0; i < 200; i++) await exact(connection, `BEGIN TRAN;
          INSERT orders (customer_id, total, status) VALUES (@c, @t, 'new');
          UPDATE customers SET balance = balance + @t WHERE id = @c;
          COMMIT`, [{ name: '@c', type: 'int', value: 1 + i % 1000 }, { name: '@t', type: 'decimal(12,2)', value: 10.5 }])
      })
      const report = []
      for (let i = 0; i < 5; i++) report.push(await timed(() => exact(connection, `SELECT TOP 20 c.email, COUNT(o.id) AS n, SUM(o.total) AS total
        FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.email ORDER BY total DESC, c.email`)))
      out.reportMs = median(report)

      const setup = await timed(() => exact(connection, setupSql(rows)))
      out.shapes = { rows, setupMs: setup, ms: {} }
      for (const [shape, sql] of queries) {
        const r = await capture(connection, { kind: 'batch', sql }, { rowLimit: 10 })
        const ms = await timed(() => capture(connection, { kind: 'batch', sql }, { rowLimit: 10 }))
        out.shapes.ms[shape] = r.errors.length ? null : ms
      }
      log(`workload done`)
    } finally { await close(connection) }
    out.afterWorkload = cgroup(id)
  } finally {
    await docker('rm', '--force', name).catch(() => {})
  }
  return out
}

const results = []
for (const target of targets) results.push(await measure(target))
const host = {
  date: new Date().toISOString().slice(0, 10),
  cpu: readFileSync('/proc/cpuinfo', 'utf8').match(/model name\s*:\s*(.*)/)?.[1],
  docker: await docker('version', '--format', '{{.Server.Version}}'),
}
if (flags.json) writeFileSync(resolve(flags.json), JSON.stringify({ host, results }, null, 2) + '\n')

// Markdown, ready for README.md.
const fmtMs = ms => ms == null ? 'error' : ms >= 1000 ? `${(ms / 1000).toFixed(2)} s` : ms >= 100 ? `${ms.toFixed(0)} ms` : ms >= 10 ? `${ms.toFixed(1)} ms` : `${ms.toFixed(2)} ms`
const fmtMiB = b => mib(b) >= 1024 ? `${(mib(b) / 1024).toFixed(2)} GiB` : `${mib(b).toFixed(1)} MiB`
const rowsOf = [
  ['Image download (compressed)', r => r.downloadBytes == null ? 'n/a' : fmtMiB(r.downloadBytes)],
  ['Image size on disk', r => fmtMiB(r.imageBytes)],
  ['Cold start: `docker run` → first query (median)', r => fmtMs(r.coldStartMs)],
  ['CPU time until ready', r => fmtMs(r.readyCpuMs)],
  ['Memory idle after start', r => fmtMiB(r.idle.used)],
  ['Memory after workload', r => fmtMiB(r.afterWorkload.used)],
  ['Memory peak (incl. page cache)', r => fmtMiB(r.afterWorkload.peak)],
  ['Login (new connection, TLS, median)', r => fmtMs(r.loginMs)],
  ['`SELECT 1` round trip (median)', r => fmtMs(r.selectOneMs)],
  ['Drop + create 2-table schema (median)', r => fmtMs(r.schemaResetMs)],
  ['1000 parameterized INSERTs', r => fmtMs(r.insertsMs)],
  ['1000 parameterized point SELECTs', r => fmtMs(r.pointReadsMs)],
  ['200 transactions (INSERT + UPDATE)', r => fmtMs(r.transactionsMs)],
  ['Join + GROUP BY report (median)', r => fmtMs(r.reportMs)],
  [`Load ${rows} + ${rows} rows (GENERATE_SERIES)`, r => fmtMs(r.shapes.setupMs)],
  [`${queries.length} query/DML shapes over ${rows} rows (total)`, r => Object.values(r.shapes.ms).includes(null) ? 'error' : fmtMs(Object.values(r.shapes.ms).reduce((a, b) => a + b, 0))],
]
console.log(`\n${host.date}, ${host.cpu}, Docker ${host.docker}\n`)
console.log(`| | ${results.map(r => r.target === 'bitsql' ? 'bitsql' : 'SQL Server').join(' | ')} |`)
console.log(`| --- | ${results.map(() => '---:').join(' | ')} |`)
for (const [label, f] of rowsOf) console.log(`| ${label} | ${results.map(f).join(' | ')} |`)
console.log(`\n| Shape (${rows} rows) | ${results.map(r => r.target === 'bitsql' ? 'bitsql' : 'SQL Server').join(' | ')} |`)
console.log(`| --- | ${results.map(() => '---:').join(' | ')} |`)
for (const [shape] of queries) console.log(`| ${shape} | ${results.map(r => fmtMs(r.shapes.ms[shape])).join(' | ')} |`)
console.log(`\nimages: ${results.map(r => `${r.target}=${r.image}`).join(', ')}`)
