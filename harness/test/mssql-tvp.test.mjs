// Table-valued parameters through the `mssql` package: `request.input(name,
// table)` with an `sql.Table` naming a user-defined table type sends a TDS
// TVP (TVP_TYPE 0xF3) to a stored procedure (RPC by name) and to
// sp_executesql (`query`). Expectations are pinned to a capture of the same
// calls against SQL Server 17.0.5005.3 (2026-10-04).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import sql from 'mssql'
import { server, skipIfUnsupported } from './support.mjs'

async function pool(t) {
  const s = await server(t)
  const p = new sql.ConnectionPool({
    server: s.host, port: s.port, user: 'sa', password: 'bitsql', database: 'master',
    options: { trustServerCertificate: true }, pool: { max: 2 },
    connectionTimeout: 5000, requestTimeout: 15000,
  })
  await p.connect()
  t.after(() => p.close())
  return p
}

async function run(t, fn) {
  try { await fn(); return true } catch (error) {
    if (skipIfUnsupported(t, error.originalError ?? error)) return false
    throw error
  }
}

function idList(rows) {
  const table = new sql.Table('dbo.IdList')
  table.columns.add('id', sql.Int, { nullable: false })
  table.columns.add('label', sql.NVarChar(20), { nullable: true })
  for (const r of rows) table.rows.add(...r)
  return table
}

test('mssql: table-valued parameters (procedure, sp_executesql, READONLY)', async t => {
  const p = await pool(t)
  await run(t, async () => {
    await p.request().batch('CREATE TYPE dbo.IdList AS TABLE (id int NOT NULL PRIMARY KEY, label nvarchar(20) NULL)')
    await p.request().batch("CREATE TABLE items (id int CONSTRAINT pk_items PRIMARY KEY, v nvarchar(10) NOT NULL); INSERT INTO items VALUES (1, N'one'), (2, N'two'), (3, N'three')")
    await p.request().batch('CREATE PROCEDURE dbo.pick @ids dbo.IdList READONLY, @min int = 0 AS SELECT i.id, i.v, x.label FROM items i JOIN @ids x ON x.id = i.id WHERE i.id >= @min ORDER BY i.id; RETURN (SELECT COUNT(*) FROM @ids)')
    const rows = [[1, 'first'], [3, null], [9, 'missing']]

    const exec = await p.request().input('ids', idList(rows)).input('min', sql.Int, 2).execute('dbo.pick')
    assert.deepEqual(exec.recordsets, [[{ id: 3, v: 'three', label: null }]])
    assert.deepEqual(exec.rowsAffected, [1, 1])
    assert.equal(exec.returnValue, 3)

    const q = await p.request().input('ids', idList(rows)).query('SELECT COUNT(*) AS n, SUM(id) AS s, MAX(label) AS m FROM @ids')
    assert.deepEqual(q.recordsets, [[{ n: 3, s: 13, m: 'missing' }]])
    assert.deepEqual(q.rowsAffected, [1])

    const typed = await p.request().input('ids', sql.TVP, idList(rows)).query('SELECT id FROM @ids ORDER BY id DESC')
    assert.deepEqual(typed.recordsets, [[{ id: 9 }, { id: 3 }, { id: 1 }]])

    const empty = await p.request().input('ids', idList([])).execute('dbo.pick')
    assert.deepEqual(empty.recordsets, [[]])
    assert.deepEqual(empty.rowsAffected, [0, 1])
    assert.equal(empty.returnValue, 0)

    await assert.rejects(p.request().input('ids', idList(rows)).query('DELETE FROM @ids'), e => {
      assert.equal(e.number, 10700)
      assert.equal(e.message, 'The table-valued parameter "@ids" is READONLY and cannot be modified.')
      return true
    })
    const after = await p.request().query('SELECT COUNT(*) AS n FROM items')
    assert.deepEqual(after.recordset, [{ n: 3 }])
  })
})
