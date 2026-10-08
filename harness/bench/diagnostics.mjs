// Interleaved native baseline / diagnostics-off / diagnostics-on comparison.
// BASELINE_BIN=... BITSQL_BIN=... node harness/bench/diagnostics.mjs > result.json
// Measures complete requests, including the extra report when enabled.
import { readFileSync } from 'node:fs'
import { spawnEmulator, emulatorConfig } from '../src/emulator.mjs'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { setupSql } from './shapes.mjs'

if (!process.env.BASELINE_BIN || !process.env.BITSQL_BIN) throw new Error('BASELINE_BIN and BITSQL_BIN are required')
const rows = Number(process.env.ROWS || 20000)
const rounds = Number(process.env.ROUNDS || 7)
const reps = Number(process.env.REPS || 20)
const shapes = [
  ['constant', 'SELECT 1 AS n'],
  ['point seek', 'SELECT id,p FROM w WHERE id=42'],
  ['scan/filter aggregate', 'SELECT COUNT(*) FROM w WHERE p>500'],
  ['equi-join', 'SELECT COUNT(*) FROM w JOIN w2 ON w2.w_id=w.id'],
  ['Top-N', 'SELECT TOP 10 id FROM w ORDER BY v,id'],
  ['correlated subquery', 'SELECT COUNT(*) FROM w WHERE (SELECT COUNT(*) FROM w2 WHERE w2.w_id=w.p)>0'],
]
const services = []
const median = a => [...a].sort((x, y) => x-y)[Math.floor(a.length/2)]
async function exact(c, sql) {
  const r = await capture(c, { kind: 'batch', sql }, { rowLimit: 10 })
  if (r.errors.length) throw new Error(JSON.stringify(r.errors))
  return r
}
const cpu = s => Number(readFileSync(`/proc/${s.pid}/schedstat`, 'utf8').split(' ')[0]) / 1e6
try {
  for (const bin of [process.env.BASELINE_BIN, process.env.BITSQL_BIN]) {
    const s = await spawnEmulator({ bin })
    services.push(s)
    s.connection = await connect(emulatorConfig(s))
    s.version = (await exact(s.connection, 'SELECT @@VERSION')).sets[0].rows[0][0]
    await exact(s.connection, setupSql(rows))
  }
  const modes = [
    { name: 'baseline', s: services[0], wrap: sql => sql },
    { name: 'off', s: services[1], wrap: sql => sql },
    { name: 'on', s: services[1], wrap: sql => `EXEC emulator.profile N'${sql.replaceAll("'", "''")}'` },
  ]
  const results = []
  for (const [name, sql] of shapes) {
    const samples = Object.fromEntries(modes.map(m => [m.name, []]))
    for (const m of modes) for (let i=0; i<3; i++) await exact(m.s.connection, m.wrap(sql))
    for (let round=0; round<rounds; round++) for (let i=0; i<modes.length; i++) {
      const m = modes[(i+round)%modes.length]
      const before = cpu(m.s), start = performance.now()
      for (let j=0; j<reps; j++) await exact(m.s.connection, m.wrap(sql))
      samples[m.name].push({ cpuMs: (cpu(m.s)-before)/reps, wallMs: (performance.now()-start)/reps })
    }
    results.push({ name, samples, medians: Object.fromEntries(Object.entries(samples).map(([key, xs]) => [key, {
      cpuMs: median(xs.map(x => x.cpuMs)), wallMs: median(xs.map(x => x.wallMs)),
    }])) })
  }
  console.log(JSON.stringify({ rows, rounds, reps, versions: services.map(s => s.version), results }, null, 2))
} finally {
  for (const s of services) {
    if (s.connection) await close(s.connection)
    await s.stop()
  }
}
