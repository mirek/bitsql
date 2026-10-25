// The point-read workload of compare.mjs, alone, against the emulator or
// the running oracle, with client CPU beside wall time, so that per-query
// server cost can be compared without the full container benchmark.
//
//   BITSQL_BIN=... node bench/points.mjs        # a fresh emulator
//   TARGET=oracle node bench/points.mjs         # the bitsql-oracle container
//   REPS=10 node bench/points.mjs
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { startOracle } from '../src/oracle.mjs'
import { connect, close, withDatabase } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'

const reps = Number(process.env.REPS || 7)
const oracle = process.env.TARGET === 'oracle'
async function exact(c, sql, params) {
  const r = await capture(c, { kind: params ? 'rpc' : 'batch', sql, params }, { rowLimit: 10 })
  if (r.errors.length) throw new Error(`${sql.slice(0, 60)}: ${r.errors[0].message}`)
}
const median = xs => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]

const server = oracle ? null : await spawnEmulator({ bin: process.env.BITSQL_BIN })
const base = oracle ? (await startOracle()).config : emulatorConfig(server)
const db = `bitsql_points_${process.pid}`
try {
  const master = await connect(base)
  await exact(master, `CREATE DATABASE ${db}`)
  try {
    const c = await connect(withDatabase(base, db))
    try {
      await exact(c, `CREATE TABLE customers (id int IDENTITY PRIMARY KEY, email nvarchar(200) NOT NULL UNIQUE, name nvarchar(100), balance decimal(12, 2) NOT NULL DEFAULT 0, created datetime2 NOT NULL DEFAULT SYSUTCDATETIME())`)
      for (let i = 0; i < 1000; i++) await exact(c, 'INSERT customers (email, name) OUTPUT INSERTED.id VALUES (@email, @name)', [{ name: '@email', type: 'nvarchar(200)', value: `user${i}@example.com` }, { name: '@name', type: 'nvarchar(100)', value: `User ${i}` }])
      const points = async () => {
        for (let i = 0; i < 1000; i++) await exact(c, 'SELECT id, email, name, balance FROM customers WHERE id = @id', [{ name: '@id', type: 'int', value: 1 + (i * 7) % 1000 }])
      }
      await points()
      const wall = [], cpu = []
      for (let r = 0; r < reps; r++) {
        const u = process.cpuUsage(), t = performance.now()
        await points()
        wall.push(performance.now() - t)
        const d = process.cpuUsage(u)
        cpu.push((d.user + d.system) / 1000)
      }
      console.log(`${oracle ? 'oracle' : 'bitsql'}: 1000 point SELECTs median ${median(wall).toFixed(1)} ms, min ${Math.min(...wall).toFixed(1)} ms, client CPU ${median(cpu).toFixed(1)} ms`)
    } finally { await close(c) }
  } finally {
    await exact(master, `DROP DATABASE ${db}`).catch(() => {})
    await close(master)
  }
} finally { await server?.stop() }
