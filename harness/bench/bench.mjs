// Query-shape benchmark against a release build of the emulator: catches
// quadratic execution paths (grouping, DISTINCT, set operations,
// subqueries) before they reach users. Not part of `npm test`.
//
//   npm run bench                    # N = 20000
//   npm run bench -- 80000           # another size (compare scaling)
//   npm run bench -- 20000 80000     # several sizes, one table per size
//   BITSQL_BIN=path npm run bench    # an existing binary (no build)
//   BENCH_ONLY=EXISTS npm run bench  # queries whose name matches a regexp
//
// Each query runs on a fresh table set of N rows; the time is the client
// round trip including the result rows. A query that exceeds the request
// work budget (default --max-request-work) reports the error instead.
import { execFileSync } from 'node:child_process'
import { readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { repoDir } from '../src/env.mjs'
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { queries, setupSql } from './shapes.mjs'

function releaseBinary() {
  if (process.env.BITSQL_BIN) return process.env.BITSQL_BIN
  execFileSync('moon', ['build', '--target', 'native', '--release'], { cwd: repoDir, stdio: ['ignore', 'ignore', 'inherit'] })
  const dir = join(repoDir, '_build', 'native', 'release', 'build', 'host')
  const exe = readdirSync(dir).find(f => f === 'host.exe')
  if (!exe) throw new Error(`no host.exe in ${dir}`)
  return join(dir, exe)
}

async function run(connection, sql) {
  const started = performance.now()
  const result = await capture(connection, { kind: 'batch', sql }, { rowLimit: 10 })
  const ms = performance.now() - started
  const error = result.errors[0]
  return { ms, error: error ? `${error.number ?? ''} ${error.message}`.trim() : null }
}

const only = process.env.BENCH_ONLY ? new RegExp(process.env.BENCH_ONLY) : null
const sizes = process.argv.slice(2).map(Number).filter(n => n > 0)
const bin = releaseBinary()
console.log(`binary ${bin} (${new Date(statSync(bin).mtimeMs).toISOString()})`)
const server = await spawnEmulator({ bin })
try {
  const config = emulatorConfig(server)
  config.options.requestTimeout = 600000
  const connection = await connect(config)
  try {
    for (const n of sizes.length ? sizes : [20000]) {
      const setup = await run(connection, setupSql(n))
      if (setup.error) throw new Error(`setup: ${setup.error}`)
      console.log(`\nN = ${n} (setup ${setup.ms.toFixed(0)} ms)`)
      for (const [name, sql] of queries) {
        if (only && !only.test(name)) continue
        const r = await run(connection, sql)
        console.log(`${r.ms.toFixed(0).padStart(8)} ms  ${name}${r.error ? `  ERROR ${r.error.slice(0, 80)}` : ''}`)
      }
    }
  } finally { await close(connection) }
} finally { await server.stop() }
