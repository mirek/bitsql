// Repeats benchmark shapes (or ad-hoc SQL) against one emulator so that
// scripts/profile.sh can sample it. Setup runs once (bench/shapes.mjs).
//
//   SHAPE=regexp REPS=30 BITSQL_BIN=... node bench/profile.mjs
//   SQL='SELECT COUNT(*) FROM w' REPS=40 BITSQL_BIN=... node bench/profile.mjs
//   WORKLOAD=requests REPS=3 BITSQL_BIN=... node bench/profile.mjs
//     (the per-request workload of compare.mjs: SELECT 1 round trips,
//     parameterized inserts and point SELECTs through sp_executesql, small
//     transactions, the join + GROUP BY report)
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { readFileSync } from 'node:fs'
import { queries, setupSql } from './shapes.mjs'

const reps = Number(process.env.REPS || 30)
const n = Number(process.env.ROWS || 20000)
const work = process.env.SQL
  ? process.env.SQL.split(';;').map(sql => [sql.trim(), sql.trim()])
  : queries.filter(([name]) => new RegExp(process.env.SHAPE || '.').test(name))
async function exact(c, sql, params) {
  const r = await capture(c, { kind: params ? 'rpc' : 'batch', sql, params }, { rowLimit: 10 })
  if (r.errors.length) throw new Error(`${sql.slice(0, 60)}: ${r.errors[0].message}`)
}

// Server CPU time (ns) from /proc/<pid>/schedstat, null where unavailable.
let serverPid = null
const cpuNs = () => {
  try { return Number(readFileSync(`/proc/${serverPid}/schedstat`, 'utf8').split(' ')[0]) } catch { return null }
}

async function timed(name, fn) {
  const t = performance.now()
  const c = cpuNs()
  await fn()
  const cpu = c === null ? '' : `  (server CPU ${((cpuNs() - c) / 1e6).toFixed(2)} ms)`
  console.log(`${(performance.now() - t).toFixed(2).padStart(9)} ms  ${name}${cpu}`)
}

// Mirrors the "test suite in miniature" of compare.mjs.
async function requests(c) {
  await exact(c, `DROP TABLE IF EXISTS orders; DROP TABLE IF EXISTS customers;
    CREATE TABLE customers (id int IDENTITY PRIMARY KEY, email nvarchar(200) NOT NULL UNIQUE, name nvarchar(100), balance decimal(12, 2) NOT NULL DEFAULT 0, created datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
    CREATE TABLE orders (id int IDENTITY PRIMARY KEY, customer_id int NOT NULL REFERENCES customers (id), total decimal(12, 2) NOT NULL, status varchar(20) NOT NULL);
    CREATE INDEX ix_orders_customer ON orders (customer_id);`)
  await timed('1000 x SELECT 1', async () => { for (let i = 0; i < 1000; i++) await exact(c, 'SELECT 1') })
  await timed('1000 parameterized INSERTs', async () => {
    for (let i = 0; i < 1000; i++) await exact(c, 'INSERT customers (email, name) OUTPUT INSERTED.id VALUES (@email, @name)', [{ name: '@email', type: 'nvarchar(200)', value: `user${i}@example.com` }, { name: '@name', type: 'nvarchar(100)', value: `User ${i}` }])
  })
  for (let r = 0; r < reps; r++) {
    await timed('1000 point SELECTs', async () => {
      for (let i = 0; i < 1000; i++) await exact(c, 'SELECT id, email, name, balance FROM customers WHERE id = @id', [{ name: '@id', type: 'int', value: 1 + (i * 7) % 1000 }])
    })
  }
  await timed('200 transactions', async () => {
    for (let i = 0; i < 200; i++) await exact(c, `BEGIN TRAN;
      INSERT orders (customer_id, total, status) VALUES (@c, @t, 'new');
      UPDATE customers SET balance = balance + @t WHERE id = @c;
      COMMIT`, [{ name: '@c', type: 'int', value: 1 + i % 1000 }, { name: '@t', type: 'decimal(12,2)', value: 10.5 }])
  })
  await timed(`${reps * 20} x join + GROUP BY report`, async () => {
    for (let i = 0; i < reps * 20; i++) await exact(c, `SELECT TOP 20 c.email, COUNT(o.id) AS n, SUM(o.total) AS total
      FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.email ORDER BY total DESC, c.email`)
  })
}

const server = await spawnEmulator({ bin: process.env.BITSQL_BIN })
serverPid = server.pid
try {
  const config = emulatorConfig(server)
  config.options.requestTimeout = 600000
  const c = await connect(config)
  try {
    if (process.env.WORKLOAD === 'requests') await requests(c)
    else await capture(c, { kind: 'batch', sql: setupSql(n) }, { rowLimit: 1 })
    for (const [name, sql] of process.env.WORKLOAD === 'requests' ? [] : work) {
      await capture(c, { kind: 'batch', sql }, { rowLimit: 10 })
      let total = 0, min = Infinity
      for (let i = 0; i < reps; i++) {
        const t = performance.now()
        await capture(c, { kind: 'batch', sql }, { rowLimit: 10 })
        const ms = performance.now() - t
        total += ms; min = Math.min(min, ms)
      }
      // min is robust against load from other processes on a shared host
      console.log(`${(total / reps).toFixed(2).padStart(8)} ms mean ${min.toFixed(2).padStart(8)} ms min  ${name}`)
    }
  } finally { await close(c) }
} finally { await server.stop() }
