// Request cancellation (TDS ATTENTION) through mssql request timeouts and
// tedious cancel(). Expectations captured against SQL Server 17.0.5005.3
// with the same calls (2026-10-04; wire probes in session/attention.mbt):
// a request blocked in WAITFOR or on another connection's lock fails with
// the ordinary request-timeout error right after its deadline (tedious waits
// for the request's own response *and* a separate DONE_ATTN message; with
// only one of them it reports "Failed to cancel request in 5000ms"), the
// interrupted statement is rolled back, earlier statements of the request
// keep their effects (an open transaction stays open), XACT_ABORT ON rolls
// the transaction back, and the pooled connection is reusable.
//
// ATTENTION_ORACLE=1 runs the same tests against the oracle (bitsql-oracle).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import sql from 'mssql'
import { Connection, Request } from 'tedious'
import { server } from './support.mjs'
import { startOracle } from '../src/oracle.mjs'

async function target(t) {
  if (process.env.ATTENTION_ORACLE === '1') {
    const { config } = await startOracle()
    return { host: '127.0.0.1', port: config.options.port, password: config.authentication.options.password, config }
  }
  const s = await server(t)
  return { host: s.host, port: s.port, password: 'bitsql', config: s.config }
}

async function pool(t, s, options = {}) {
  const p = new sql.ConnectionPool({
    server: s.host, port: s.port, user: 'sa', password: s.password, database: 'master',
    options: { trustServerCertificate: true, ...options }, pool: { max: 1 },
    connectionTimeout: 5000, requestTimeout: 150,
  })
  await p.connect()
  t.after(() => p.close())
  return p
}

async function timesOut(promise) {
  const t0 = Date.now()
  await assert.rejects(promise, e => {
    assert.equal(e.code, 'ETIMEOUT')
    assert.equal(e.message, 'Timeout: Request failed to complete in 150ms')
    return true
  })
  const ms = Date.now() - t0
  assert.ok(ms < 1500, `cancellation took ${ms} ms`)
}

for (const cancelTimeout of [undefined, 400]) {
  test(`mssql requestTimeout cancels WAITFOR promptly (cancelTimeout ${cancelTimeout ?? 'default'})`, async t => {
    const s = await target(t)
    const p = await pool(t, s, cancelTimeout ? { cancelTimeout } : {})
    await timesOut(p.request().query("WAITFOR DELAY '00:00:01'; SELECT 7 AS value;"))
    const r = await p.request().query('SELECT 42 AS value, @@TRANCOUNT AS tc')
    assert.deepEqual(r.recordset, [{ value: 42, tc: 0 }])
  })
}

test('mssql requestTimeout cancels a lock-blocked UPDATE; the row is unchanged', async t => {
  const s = await target(t)
  const holder = await pool(t, s)
  const p = await pool(t, s)
  const name = `attn_${process.pid}_${Date.now()}`
  await holder.request().batch(`CREATE TABLE ${name} (id int PRIMARY KEY, v int); INSERT ${name} VALUES (1, 10)`)
  t.after(() => holder.request().batch(`DROP TABLE ${name}`).catch(() => {}))
  const tx = new sql.Transaction(holder)
  await tx.begin()
  await new sql.Request(tx).query(`UPDATE ${name} SET v = 99 WHERE id = 1`)
  await timesOut(p.request().query(`UPDATE ${name} SET v = 50 WHERE id = 1; SELECT 1 AS x`))
  const tc = await p.request().query('SELECT @@TRANCOUNT AS tc')
  assert.deepEqual(tc.recordset, [{ tc: 0 }])
  await tx.rollback()
  const r = await p.request().query(`SELECT v FROM ${name} WHERE id = 1`)
  assert.deepEqual(r.recordset, [{ v: 10 }])
})

// tedious cancel() on one connection: transaction state after ATTENTION.
async function connection(t, s) {
  const c = new Connection({ ...s.config, options: { ...s.config.options, requestTimeout: 15000 } })
  c.on('error', () => {})
  await new Promise((res, rej) => c.connect(e => e ? rej(e) : res()))
  t.after(() => c.close())
  const run = (text, { cancelAfter, rpc = false } = {}) => new Promise(res => {
    const rows = []
    const r = new Request(text, (error, rowCount) => res({ error: error?.code, rows }))
    r.on('row', row => rows.push(row.map(x => x.value)))
    rpc ? c.execSql(r) : c.execSqlBatch(r)
    if (cancelAfter !== undefined) setTimeout(() => r.cancel(), cancelAfter)
  })
  return run
}

test('tedious cancel(): the open transaction survives, XACT_ABORT ON rolls it back', async t => {
  const s = await target(t)
  const run = await connection(t, s)
  await run('CREATE TABLE #a (id int PRIMARY KEY, v int); INSERT #a VALUES (1, 10)')
  const cancelled = await run("BEGIN TRAN; UPDATE #a SET v = 11 WHERE id = 1; WAITFOR DELAY '00:00:01'; SELECT 2 AS b", { cancelAfter: 100 })
  assert.deepEqual(cancelled, { error: 'ECANCEL', rows: [] })
  assert.deepEqual((await run('SELECT @@TRANCOUNT, XACT_STATE(), (SELECT v FROM #a WHERE id = 1)')).rows, [[1, 1, 11]])
  await run('ROLLBACK')

  const rpc = await run("BEGIN TRAN; UPDATE #a SET v = 12 WHERE id = 1; WAITFOR DELAY '00:00:01'", { cancelAfter: 100, rpc: true })
  assert.deepEqual(rpc, { error: 'ECANCEL', rows: [] })
  assert.deepEqual((await run('SELECT @@TRANCOUNT, (SELECT v FROM #a WHERE id = 1)')).rows, [[1, 12]])
  await run('ROLLBACK')

  await run("SET XACT_ABORT ON; BEGIN TRAN; UPDATE #a SET v = 13 WHERE id = 1; WAITFOR DELAY '00:00:01'", { cancelAfter: 100 })
  // (XACT_STATE() next to a table read is 1 even outside a transaction)
  assert.deepEqual((await run('SELECT @@TRANCOUNT, XACT_STATE()')).rows, [[0, 0]])
  assert.deepEqual((await run('SELECT v FROM #a WHERE id = 1')).rows, [[10]])
  await run('SET XACT_ABORT OFF')

  // statements completed before a passed WAITFOR stay; the next one is cut
  const partial = await run("INSERT #a VALUES (2, 20); WAITFOR DELAY '00:00:00.05'; INSERT #a VALUES (3, 30); WAITFOR DELAY '00:00:01'; INSERT #a VALUES (4, 40)", { cancelAfter: 200 })
  assert.equal(partial.error, 'ECANCEL')
  assert.deepEqual((await run('SELECT id FROM #a ORDER BY id')).rows, [[1], [2], [3]])
})
