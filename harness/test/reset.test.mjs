// tedious connection.reset() (RESETCONNECTION header bit): expectations
// captured against SQL Server 17.0.5005.3 with the same calls (2026-10-03):
// the open transaction is rolled back (ENVCHANGE 10, then RESETACK 18), temp
// tables are dropped and SET options, CONTEXT_INFO and LOCK_TIMEOUT return to
// their defaults.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Connection, Request } from 'tedious'
import { server, skipIfUnsupported } from './support.mjs'

test('tedious reset() rolls back and resets session state', async t => {
  const s = await server(t)
  const c = new Connection(s.config)
  c.on('error', () => {})
  await new Promise((res, rej) => c.connect(e => e ? rej(e) : res()))
  t.after(() => c.close())
  const envchanges = []
  c.debug.token = tok => { if (tok.name === 'ENVCHANGE') envchanges.push(tok.type) }
  const q = sql => new Promise((res, rej) => {
    const rows = []
    const r = new Request(sql, e => e ? rej(e) : res(rows))
    r.on('row', row => rows.push(row.map(x => x.value)))
    c.execSqlBatch(r)
  })
  try {
    await q('CREATE TABLE #t (a int); SET NOCOUNT ON; SET XACT_ABORT ON; SET CONTEXT_INFO 0x01; SET LOCK_TIMEOUT 5; SET DATEFIRST 3; BEGIN TRAN; SELECT 1')
    envchanges.length = 0
    await new Promise((res, rej) => c.reset(e => e ? rej(e) : res()))
    assert.deepEqual(envchanges.slice(0, 2), ['ROLLBACK_TXN', 'RESET_CONNECTION'])
    const rows = await q("SELECT @@TRANCOUNT tc, OBJECT_ID('tempdb..#t') t, @@OPTIONS & 512 nocount, @@OPTIONS & 16384 xact_abort, CONTEXT_INFO() ci, @@LOCK_TIMEOUT lt, @@DATEFIRST df")
    assert.deepEqual(rows, [[0, null, 0, 0, null, -1, 7]])
  } catch (error) {
    if (skipIfUnsupported(t, error)) return
    throw error
  }
})
