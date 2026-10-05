// Repeats benchmark shapes (or ad-hoc SQL) against one emulator so that
// scripts/profile.sh can sample it. Setup runs once (bench/shapes.mjs).
//
//   SHAPE=regexp REPS=30 BITSQL_BIN=... node bench/profile.mjs
//   SQL='SELECT COUNT(*) FROM w' REPS=40 BITSQL_BIN=... node bench/profile.mjs
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { queries, setupSql } from './shapes.mjs'

const reps = Number(process.env.REPS || 30)
const n = Number(process.env.ROWS || 20000)
const work = process.env.SQL
  ? process.env.SQL.split(';;').map(sql => [sql.trim(), sql.trim()])
  : queries.filter(([name]) => new RegExp(process.env.SHAPE || '.').test(name))
const server = await spawnEmulator({ bin: process.env.BITSQL_BIN })
try {
  const config = emulatorConfig(server)
  config.options.requestTimeout = 600000
  const c = await connect(config)
  try {
    await capture(c, { kind: 'batch', sql: setupSql(n) }, { rowLimit: 1 })
    for (const [name, sql] of work) {
      await capture(c, { kind: 'batch', sql }, { rowLimit: 10 })
      const t = performance.now()
      for (let i = 0; i < reps; i++) await capture(c, { kind: 'batch', sql }, { rowLimit: 10 })
      console.log(`${((performance.now() - t) / reps).toFixed(2).padStart(8)} ms  ${name}`)
    }
  } finally { await close(c) }
} finally { await server.stop() }
