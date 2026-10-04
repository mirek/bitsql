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

const queries = [
  ['GROUP BY p (997 groups)', 'SELECT p, COUNT(*) FROM w GROUP BY p'],
  ['GROUP BY v (5003 groups)', 'SELECT v, COUNT(*) FROM w GROUP BY v'],
  ['SELECT DISTINCT v', 'SELECT DISTINCT v FROM w'],
  ['COUNT(DISTINCT v)', 'SELECT COUNT(DISTINCT v) FROM w'],
  ['UNION', 'SELECT v FROM w UNION SELECT v FROM w'],
  ['EXCEPT', 'SELECT v FROM w EXCEPT SELECT v FROM w WHERE id % 2 = 0'],
  ['INTERSECT', 'SELECT p FROM w INTERSECT SELECT w_id FROM w2'],
  ['IN (uncorrelated subquery)', 'SELECT COUNT(*) FROM w WHERE id IN (SELECT w_id FROM w2)'],
  ['NOT IN (uncorrelated subquery)', 'SELECT COUNT(*) FROM w WHERE p NOT IN (SELECT p FROM w WHERE id < 100)'],
  ['EXISTS (correlated, unindexed)', 'SELECT COUNT(*) FROM w WHERE EXISTS (SELECT 1 FROM w2 WHERE w2.w_id = w.id)'],
  ['scalar subquery (correlated)', 'SELECT COUNT(*) FROM w WHERE (SELECT COUNT(*) FROM w2 WHERE w2.w_id = w.p) > 0'],
  ['scalar subquery (uncorrelated)', 'SELECT COUNT(*) FROM w WHERE p = (SELECT MAX(p) FROM w2 JOIN w ON w.id = w2.id)'],
  ['equi-join', 'SELECT COUNT(*) FROM w JOIN w2 ON w2.w_id = w.id'],
  ['ORDER BY v', 'SELECT TOP 10 id FROM w ORDER BY v, id'],
  ['ROW_NUMBER over v', 'SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY v ORDER BY id) AS r FROM w) x WHERE r = 1'],
  // DML, rolled back
  ['DELETE WHERE IN (subquery)', 'BEGIN TRAN; DELETE w WHERE id IN (SELECT w_id FROM w2); ROLLBACK'],
  ['UPDATE FROM join', 'BEGIN TRAN; UPDATE w SET p = w2.w_id FROM w JOIN w2 ON w2.id = w.id; ROLLBACK'],
  ['UPDATE all rows', 'BEGIN TRAN; UPDATE w SET p = p + 1; ROLLBACK'],
  ['INSERT with FOREIGN KEY', 'BEGIN TRAN; INSERT wc SELECT id, id FROM w; ROLLBACK'],
  ['DELETE parent rows (FK checked)', 'BEGIN TRAN; INSERT wc SELECT id, id FROM w WHERE id % 2 = 0; DELETE w WHERE id % 2 = 1; ROLLBACK'],
  ['DELETE with ON DELETE CASCADE', 'BEGIN TRAN; INSERT wcc SELECT id, id FROM w; DELETE w; ROLLBACK'],
  ['MERGE', 'BEGIN TRAN; MERGE w2 AS t USING w AS s ON t.id = s.id WHEN MATCHED THEN UPDATE SET w_id = s.p WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.p); ROLLBACK'],
]

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
      const setup = await run(connection, `
        DROP TABLE IF EXISTS wc; DROP TABLE IF EXISTS wcc; DROP TABLE IF EXISTS w; DROP TABLE IF EXISTS w2;
        CREATE TABLE w (id int PRIMARY KEY, p int, v nvarchar(20));
        INSERT w SELECT g.value, g.value % 997, CONCAT(N'v', g.value % 5003) FROM GENERATE_SERIES(1, ${n}) g;
        CREATE TABLE w2 (id int PRIMARY KEY, w_id int);
        INSERT w2 SELECT g.value, g.value * 3 FROM GENERATE_SERIES(1, ${n}) g;
        CREATE TABLE wc (id int PRIMARY KEY, w_id int REFERENCES w (id));
        CREATE TABLE wcc (id int PRIMARY KEY, w_id int REFERENCES w (id) ON DELETE CASCADE);`)
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
