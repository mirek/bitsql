import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { Connection, Request } from 'tedious'
import mssql from 'mssql'
import { start, version } from 'bitsql'

const cjs = createRequire(import.meta.url)('bitsql')

function query(config, sql) {
  return new Promise((resolve, reject) => {
    const connection = new Connection(config)
    connection.on('error', () => {})
    connection.connect(error => {
      if (error) return reject(error)
      const rows = []
      const request = new Request(sql, error => { connection.close(); error ? reject(error) : resolve(rows) })
      request.on('row', columns => rows.push(columns.map(c => c.value)))
      connection.execSql(request)
    })
  })
}

test('CommonJS and ESM entry points agree', () => {
  assert.equal(cjs.start, start)
  assert.equal(cjs.version, version)
})

test('tedious config, TLS, named database', async () => {
  const server = await start({ databases: ['app'] })
  try {
    const [[db, ver, encrypted]] = await query(server.tedious('app'),
      'SELECT DB_NAME(), @@VERSION, encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID')
    assert.equal(db, 'app')
    assert.equal(ver, `mirek/bitsql@${version}`)
    assert.equal(encrypted, 'TRUE')
  } finally { await server.stop() }
  await server.stop()
})

test('mssql config and connection string, TLS off, auto-created databases', async () => {
  const server = await start({ tls: false, autoCreateDatabases: true })
  try {
    for (const [config, db] of [[server.mssql('t1'), 't1'], [server.connectionString('t2'), 't2']]) {
      const pool = await new mssql.ConnectionPool(config).connect()
      try {
        const result = await pool.request().input('n', mssql.Int, 41).query('SELECT DB_NAME() AS db, @n + 1 AS n')
        assert.deepEqual(result.recordset[0], { db, n: 42 })
      } finally { await pool.close() }
    }
  } finally { await server.stop() }
})

test('servers are independent', async () => {
  const [a, b] = await Promise.all([start(), start()])
  try {
    await query(a.tedious(), 'CREATE TABLE t (id int)')
    await assert.rejects(query(b.tedious(), 'SELECT * FROM t'), /Invalid object name 't'/)
  } finally { await Promise.all([a.stop(), b.stop()]) }
})

test('WAITFOR runs on a host timer', async () => {
  const server = await start()
  try {
    const started = performance.now()
    assert.deepEqual(await query(server.tedious(), "WAITFOR DELAY '00:00:00.100'; SELECT 1"), [[1]])
    assert.ok(performance.now() - started >= 90)
  } finally { await server.stop() }
})

test('a taken port fails', async () => {
  const first = await start()
  try {
    await assert.rejects(start({ port: first.port }), /EADDRINUSE/)
  } finally { await first.stop() }
})

test('awaiting stop() completes with nothing else keeping the process alive', () => {
  const script = "require('bitsql').start().then(s => s.stop()).then(() => console.log('stopped'))"
  const result = spawnSync(process.execPath, ['-e', script], { cwd: import.meta.dirname, timeout: 10000, encoding: 'utf8' })
  assert.equal(result.stdout.trim(), 'stopped')
})

test('a forgotten stop() does not keep the process alive', () => {
  const script = `
    const { start } = require('bitsql')
    const { Connection } = require('tedious')
    start().then(s => { const c = new Connection(s.tedious()); c.connect(() => { c.close(); console.log('ok') }) })`
  const result = spawnSync(process.execPath, ['-e', script], { cwd: import.meta.dirname, timeout: 10000, encoding: 'utf8' })
  assert.equal(result.stdout.trim(), 'ok')
  assert.equal(result.status, 0)
})
