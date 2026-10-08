import { test } from 'node:test'
import assert from 'node:assert/strict'
import { connect, close } from '../src/client.mjs'
import { capture } from '../src/capture-core.mjs'
import { server } from './support.mjs'

const command = (op, sql) => `EXEC emulator.${op} @sql=N'${sql.replaceAll("'", "''")}'`
const report = result => JSON.parse(result.sets.at(-1).rows[0][1])
async function fixture(t) {
  const s = await server(t)
  const c = await connect(s.config)
  t.after(() => close(c))
  const run = sql => capture(c, { kind: 'batch', sql })
  const setup = await run('CREATE TABLE diagnostic_data(id int NOT NULL, n int NOT NULL); INSERT diagnostic_data SELECT value, 101-value FROM GENERATE_SERIES(1,100);')
  assert.deepEqual(setup.errors, [])
  return { c, run }
}

test('on-demand diagnostics preserve metadata/results and expose scan-to-seek improvement', async t => {
  const { run } = await fixture(t)
  const sql = 'SELECT id,n FROM diagnostic_data WHERE id=42'
  const normal = await run(sql)
  assert.deepEqual(normal.errors, [])
  const explained = await run(command('explain', sql))
  assert.deepEqual(explained.errors, [])
  assert.equal(explained.sets.length, 1)
  assert.match(explained.sets[0].rows[0][0], /diagnostic_data/)
  assert.equal(report(explained).mode, 'explain')
  assert.equal(report(explained).counters, null)
  assert.equal(report(explained).plan.kind, 'logical')
  const scan = await run(command('profile', sql))
  assert.deepEqual(scan.errors, [])
  assert.deepEqual(scan.sets[0], normal.sets[0])
  assert.equal(report(scan).schema_version, 1)
  assert.equal(report(scan).returned_rows, '1')
  assert.deepEqual((await run('CREATE INDEX diagnostic_ix ON diagnostic_data(id)')).errors, [])
  const seek = await run(command('profile', sql))
  assert.deepEqual(seek.errors, [])
  assert.deepEqual(seek.sets[0], normal.sets[0])
  assert.equal(report(seek).counters.seek_hits, '1')
  assert.equal(report(seek).counters.seek_candidates, '1')
  assert.ok(BigInt(report(scan).counters.source_rows) > BigInt(report(seek).counters.source_rows))
  assert.deepEqual((await run(sql)).sets, normal.sets)
  const empty = await run('SELECT * FROM sys.query_store_runtime_stats')
  assert.deepEqual(empty.errors, [])
  assert.deepEqual(empty.sets[0].rows, [])
})

test('physical diagnostics distinguish real join and Top-N choices', async t => {
  const { run } = await fixture(t)
  for (const [sql, algorithm] of [
    ['SELECT TOP 3 id,n FROM diagnostic_data ORDER BY n', 'top_heap'],
    ['SELECT a.id FROM diagnostic_data a JOIN diagnostic_data b ON a.id=b.id', 'hash_equi_join'],
    ['SELECT a.id FROM diagnostic_data a JOIN diagnostic_data b ON a.id>b.id WHERE a.id<3', 'nested_loop_join'],
  ]) {
    const normal = await run(sql)
    const profiled = await run(command('profile', sql))
    assert.deepEqual(profiled.errors, normal.errors)
    assert.deepEqual(profiled.sets[0], normal.sets[0])
    assert.ok(report(profiled).counters.physical_events.some(e => e.algorithm === algorithm), JSON.stringify(report(profiled)))
  }
})

test('explain does not execute, failed profile does not leak, and unsupported forms fail explicitly', async t => {
  const { run } = await fixture(t)
  assert.deepEqual((await run('CREATE SEQUENCE diagnostic_seq AS int START WITH 1; CREATE SEQUENCE diagnostic_control AS int START WITH 1')).errors, [])
  assert.deepEqual((await run(command('explain', 'SELECT NEXT VALUE FOR diagnostic_seq AS n'))).errors, [])
  assert.deepEqual((await run('SELECT NEXT VALUE FOR diagnostic_seq AS n')).sets,
    (await run('SELECT NEXT VALUE FOR diagnostic_control AS n')).sets)
  const sql = 'SELECT 10/(id-id) FROM diagnostic_data' 
  assert.deepEqual((await run(command('explain', sql))).errors, [])
  const normal = await run(sql)
  const failed = await run(command('profile', sql))
  assert.deepEqual(failed.errors.map(e => e.number), normal.errors.map(e => e.number))
  assert.equal(failed.sets.length, 1, 'no success report after an execution error')
  for (const invalid of ['SELECT 1; SELECT 2', 'DELETE diagnostic_data', 'SELECT id INTO diagnostic_copy FROM diagnostic_data', 'SELECT @x=1']) {
    const bad = await run(command('profile', invalid))
    assert.ok(bad.errors.some(e => e.number >= 50100 && e.number <= 50199), invalid)
  }
  const clean = await run(command('profile', 'SELECT 1 AS n'))
  assert.deepEqual(clean.errors, [])
  assert.equal(report(clean).counters.source_calls, '0')
  assert.equal(report(clean).returned_rows, '1')
  const plain = await run('SELECT 1 AS n')
  assert.equal(plain.sets.length, 1)
  assert.deepEqual(plain.sets[0], clean.sets[0])
})

test('diagnostics support direct RPC and reject unknown/output arguments', async t => {
  const { c, run } = await fixture(t)
  const r = await capture(c, { kind: 'proc', sql: 'emulator.profile', params: [
    { name: 'sql', type: 'nvarchar(max)', value: 'SELECT id FROM diagnostic_data WHERE id=42' },
  ] })
  assert.deepEqual(r.errors, [])
  assert.equal(report(r).mode, 'profile')
  for (const sql of ["EXEC emulator.profile @unknown=N'SELECT 1'", "EXEC emulator.explain NULL", "EXEC emulator.profile N'SELECT 1', 2"]) {
    const bad = await run(sql)
    assert.ok(bad.errors.some(e => e.number >= 50100 && e.number <= 50199))
  }
})

test('profile preserves CTE, subquery, aggregate, serialization and session semantics', async t => {
  const { run } = await fixture(t)
  for (const sql of [
    'WITH q AS (SELECT id FROM diagnostic_data WHERE id<4) SELECT * FROM q UNION ALL SELECT 42',
    'SELECT a.id,(SELECT COUNT(*) FROM diagnostic_data b WHERE b.id<a.id) AS n FROM diagnostic_data a WHERE a.id<4',
    'SELECT id%3 AS g, SUM(n) AS n FROM diagnostic_data GROUP BY id%3 ORDER BY g',
    'SELECT TOP 3 id,n FROM diagnostic_data ORDER BY id FOR JSON PATH',
    'SELECT TOP 3 id,n FROM diagnostic_data ORDER BY id FOR XML RAW',
    'SELECT @@TRANCOUNT AS trancount,XACT_STATE() AS state FROM diagnostic_data WHERE id=1',
  ]) {
    const normal = await run(sql)
    const profiled = await run(command('profile', sql))
    assert.deepEqual(normal.errors, [], sql)
    assert.deepEqual(profiled.errors, [], sql)
    assert.deepEqual(profiled.sets[0], normal.sets[0], sql)
    assert.equal(report(profiled).returned_rows, String(normal.sets[0].rows.length))
  }
  const prefix = 'DECLARE @id int=42; DECLARE @ids TABLE(id int); INSERT @ids VALUES(@id); '
  const sql = 'SELECT d.id FROM diagnostic_data d JOIN @ids i ON i.id=d.id WHERE d.id=@id'
  assert.deepEqual((await run(prefix + command('profile', sql))).sets[0], (await run(prefix + sql)).sets[0])
  const failSql = 'SELECT 10/(id-3) AS n FROM diagnostic_data'
  const normal = await run(failSql)
  const profiled = await run(command('profile', failSql))
  assert.deepEqual(profiled.sets, normal.sets, 'partial rows survive the error')
  assert.deepEqual(profiled.errors.map(e => e.number), normal.errors.map(e => e.number))
})
