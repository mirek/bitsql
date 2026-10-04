// A typical application flow through the `mssql` package (default pool
// validation, parameters, OUTPUT, Transaction via TDS transaction manager
// requests, PreparedStatement, stored procedure with OUTPUT parameters, bulk
// insert). Everything must behave as against SQL Server.
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

// Runs fn; explicit emulator "not supported" errors skip the test.
async function run(t, fn) {
  try { await fn(); return true } catch (error) {
    if (skipIfUnsupported(t, error.originalError ?? error)) return false
    throw error
  }
}

test('mssql: parameters, OUTPUT INSERTED, transaction commit and rollback', async t => {
  const p = await pool(t)
  await run(t, async () => {
    await p.request().batch('CREATE TABLE users (id int IDENTITY(1,1) CONSTRAINT pk_users PRIMARY KEY, name nvarchar(50) NOT NULL, age int NULL)')
    const ins = await p.request().input('name', sql.NVarChar(50), 'ada').input('age', sql.Int, 36)
      .query('INSERT INTO users (name, age) OUTPUT INSERTED.id VALUES (@name, @age)')
    assert.deepEqual(ins.recordset, [{ id: 1 }])
    assert.deepEqual(ins.rowsAffected, [1])

    const tx = new sql.Transaction(p)
    await tx.begin()
    await new sql.Request(tx).input('n', sql.NVarChar, 'bob').query('INSERT INTO users (name) VALUES (@n)')
    await tx.commit()

    const tx2 = new sql.Transaction(p)
    await tx2.begin(sql.ISOLATION_LEVEL.SERIALIZABLE)
    await new sql.Request(tx2).query("INSERT INTO users (name) VALUES (N'carol')")
    await tx2.rollback()

    const all = await p.request().query('SELECT id, name, age FROM users ORDER BY id')
    assert.deepEqual(all.recordset, [{ id: 1, name: 'ada', age: 36 }, { id: 2, name: 'bob', age: null }])
  })
})

test('mssql: PreparedStatement and stored procedure with OUTPUT', async t => {
  const p = await pool(t)
  await run(t, async () => {
    await p.request().batch('CREATE TABLE items (id int CONSTRAINT pk_items PRIMARY KEY, v nvarchar(10))')
    const ps = new sql.PreparedStatement(p)
    ps.input('id', sql.Int)
    ps.input('v', sql.NVarChar(10))
    await ps.prepare('INSERT INTO items (id, v) VALUES (@id, @v)')
    for (const [id, v] of [[1, 'a'], [2, 'b'], [3, 'c']]) await ps.execute({ id, v })
    await ps.unprepare()

    await p.request().batch(`CREATE PROCEDURE dbo.count_items @min int, @n int OUTPUT AS
      BEGIN SET NOCOUNT ON; SELECT @n = COUNT(*) FROM items WHERE id >= @min; SELECT id, v FROM items WHERE id >= @min ORDER BY id; RETURN 7; END`)
    const r = await p.request().input('min', sql.Int, 2).output('n', sql.Int).execute('dbo.count_items')
    assert.equal(r.output.n, 2)
    assert.equal(r.returnValue, 7)
    assert.deepEqual(r.recordset, [{ id: 2, v: 'b' }, { id: 3, v: 'c' }])
  })
})

test('mssql: bulk insert', async t => {
  const p = await pool(t)
  await run(t, async () => {
    await p.request().batch('CREATE TABLE bulk_t (id int NOT NULL, name nvarchar(20) NULL)')
    const table = new sql.Table('bulk_t')
    table.columns.add('id', sql.Int, { nullable: false })
    table.columns.add('name', sql.NVarChar(20), { nullable: true })
    table.rows.add(1, 'x')
    table.rows.add(2, null)
    const r = await p.request().bulk(table)
    assert.equal(r.rowsAffected, 2)
    const rows = await p.request().query('SELECT id, name FROM bulk_t ORDER BY id')
    assert.deepEqual(rows.recordset, [{ id: 1, name: 'x' }, { id: 2, name: null }])
  })
})

// Expectations captured from SQL Server 17.0.5005.3 with the same calls
// (scratch probe, 2026-10-03): CHECK constraints are skipped unless
// checkConstraints; NOT NULL is enforced (515 + 3621); identity is generated.
test('tedious bulk load: options and errors as captured', async t => {
  const { Connection, Request, TYPES } = await import('tedious')
  const s = await server(t)
  const c = new Connection(s.config)
  c.on('error', () => {})
  await new Promise((res, rej) => c.connect(e => e ? rej(e) : res()))
  t.after(() => c.close())
  const infos = []
  c.on('infoMessage', m => infos.push(m.number))
  const batch = text => new Promise((res, rej) => {
    const rows = []
    const r = new Request(text, e => e ? rej(e) : res(rows))
    r.on('row', row => rows.push(row.map(x => x.value)))
    c.execSqlBatch(r)
  })
  const load = (options, rows) => new Promise(res => {
    const bl = c.newBulkLoad('dbo.bulk_probe', options, (err, rowCount) => res({ number: err?.number, message: err?.message, rowCount }))
    bl.addColumn('a', TYPES.Int, { nullable: false })
    bl.addColumn('name', TYPES.NVarChar, { length: 20, nullable: true })
    c.execBulkLoad(bl, rows)
  })
  await run(t, async () => {
    await batch("CREATE TABLE dbo.bulk_probe (id int IDENTITY(1,1) NOT NULL, a int NOT NULL, name nvarchar(20) NULL CONSTRAINT ck_name CHECK (name <> 'bad'))")
    assert.deepEqual(await load({}, [{ a: 1, name: 'x' }, { a: 2, name: null }]), { number: undefined, message: undefined, rowCount: 2 })
    assert.deepEqual(await load({ checkConstraints: true }, [{ a: 3, name: 'bad' }]), {
      number: 547, rowCount: 0,
      message: 'The INSERT statement conflicted with the CHECK constraint "ck_name". The conflict occurred in database "master", table "dbo.bulk_probe", column \'name\'.',
    })
    assert.deepEqual(await load({}, [{ a: 4, name: 'bad' }]), { number: undefined, message: undefined, rowCount: 1 })
    infos.length = 0
    const r = await load({}, [{ a: null, name: 'n' }])
    assert.equal(r.number, 515)
    assert.deepEqual(infos, [3621])
    assert.deepEqual(await batch('SELECT id, a, name FROM dbo.bulk_probe ORDER BY id'), [[1, 1, 'x'], [2, 2, null], [4, 4, 'bad']])
  })
})
