// Client-level smoke: tedious and mssql log in and run SELECT 1.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Request } from 'tedious'
import sql from 'mssql'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { connect, close } from '../src/client.mjs'
import { query } from '../src/capture-core.mjs'
import { repoDir } from '../src/env.mjs'
import { server, skipIfUnsupported } from './support.mjs'

test('tedious logs in (encrypt:true, its default) and the connection is LoggedIn', async t => {
  const s = await server(t)
  const connection = await connect(s.config)
  t.after(() => close(connection))
  assert.equal(connection.state.name, 'LoggedIn')
})

test('tedious SELECT 1', async t => {
  const s = await server(t)
  const connection = await connect(s.config)
  t.after(() => close(connection))
  const rows = []
  let columns
  try {
    await new Promise((resolve, reject) => {
      const request = new Request('SELECT 1', error => error ? reject(error) : resolve())
      request.on('columnMetadata', c => { columns = c })
      request.on('row', row => rows.push(row.map(c => c.value)))
      connection.execSqlBatch(request)
    })
  } catch (error) {
    if (skipIfUnsupported(t, error)) return
    throw error
  }
  assert.deepEqual(rows, [[1]])
  assert.equal(columns[0].type.name, 'Int')
})

test('mssql pool runs SELECT 1 AS a', async t => {
  const s = await server(t)
  const pool = new sql.ConnectionPool({
    server: s.host, port: s.port, user: 'sa', password: 'bitsql', database: 'master',
    options: { encrypt: false, trustServerCertificate: true }, pool: { max: 1 },
    // mssql validates every pooled connection with `SELECT 1;` over RPC by
    // default; until the emulator runs SQL that makes connect() hang to timeout.
    validateConnection: 'socket', connectionTimeout: 5000, requestTimeout: 15000,
  })
  await pool.connect()
  t.after(() => pool.close())
  let result
  try { result = await pool.request().query('SELECT 1 AS a') }
  catch (error) {
    if (skipIfUnsupported(t, error.originalError ?? error)) return
    throw error
  }
  assert.deepEqual(result.recordset, [{ a: 1 }])
})

// Not SQL Server behavior: @@VERSION names the bitsql release (moon.mod
// version) so a client can tell which emulator build it reached.
test('@@VERSION names the bitsql release', async t => {
  const s = await server(t)
  const connection = await connect(s.config)
  t.after(() => close(connection))
  const version = readFileSync(join(repoDir, 'moon.mod'), 'utf8').match(/^version = "(.*)"/m)[1]
  const { rows } = await query(connection, 'SELECT @@VERSION')
  assert.equal(rows[0][0], `Microsoft SQL Server 2025 (bitsql emulator ${version})`)
})
