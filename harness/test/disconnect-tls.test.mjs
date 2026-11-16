// A lock holder and its blocked waiters disconnecting together over TLS
// (2026-11-16, reported against 0.1.31 behind docker's port proxy: SIGSEGV,
// exit 139). The holder's disconnect rolls back and releases the lock, so
// the waiters' UPDATEs run and their replies go out while those clients are
// gone too. A TLS write suspends while flushing; the waiter's own EOF ended
// its TLS session meanwhile, which freed the OpenSSL object the resumed
// write then used. With only that fixed, the resumed write spun forever
// (EOF had closed OpenSSL's transport). The proxy below reproduces
// docker-proxy's part: the client's disconnect reaches the server as a FIN
// (its write side stays open), and the server's pending replies drain
// slowly instead of failing.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { Connection, Request } from 'tedious'
import { server } from './support.mjs'

// Client gone → half-close the backend and stop reading it; drain it in
// small steps a little later, then drop it.
function halfCloseProxy(targetPort) {
  const sockets = new Set()
  const proxy = net.createServer(client => {
    const backend = net.connect(targetPort, '127.0.0.1')
    sockets.add(client); sockets.add(backend)
    let gone = false
    client.on('data', d => backend.write(d))
    backend.on('data', d => { if (!gone) client.write(d) })
    const disconnect = () => {
      if (gone) return
      gone = true
      backend.pause()
      backend.end()
      const drip = setInterval(() => backend.read(16384), 5)
      setTimeout(() => { clearInterval(drip); backend.resume() }, 400)
      setTimeout(() => backend.destroy(), 1500)
    }
    client.on('end', disconnect); client.on('close', disconnect); client.on('error', disconnect)
    backend.on('error', () => client.destroy())
    backend.on('end', () => client.end())
  })
  return new Promise(resolve => proxy.listen(0, '127.0.0.1', () => resolve({
    port: proxy.address().port,
    close: () => { for (const s of sockets) s.destroy(); proxy.close() },
  })))
}

function connect(port, password, requestTimeout = 0) {
  return new Promise((resolve, reject) => {
    const c = new Connection({
      server: '127.0.0.1',
      authentication: { type: 'default', options: { userName: 'sa', password } },
      options: { port, encrypt: true, trustServerCertificate: true, database: 'master', requestTimeout, connectTimeout: 5000 },
    })
    c.on('connect', e => e ? reject(e) : resolve(c))
    c.on('error', () => {})
    c.connect()
  })
}

function batch(c, sql) {
  const rows = []
  return new Promise((resolve, reject) => {
    const r = new Request(sql, e => e ? reject(e) : resolve(rows))
    r.on('row', cols => rows.push(cols.map(col => col.value)))
    c.execSqlBatch(r)
  })
}

const sleep = ms => new Promise(r => setTimeout(r, ms))

test('lock holder and blocked waiters disconnecting together keep the server up', { timeout: 60000 }, async t => {
  const s = await server(t)
  const proxy = await halfCloseProxy(s.port)
  t.after(() => proxy.close())
  // requests time out: a wedged server (it once spun in SSL_write) fails fast
  const setup = await connect(s.port, 'bitsql', 5000)
  t.after(() => setup.close())
  await batch(setup, 'CREATE TABLE dbo.disc_tls (id int PRIMARY KEY, v int); INSERT dbo.disc_tls VALUES (1, 1)')
  for (let round = 0; round < 3; round++) {
    const holder = await connect(proxy.port, 'bitsql')
    await batch(holder, 'BEGIN TRAN; UPDATE dbo.disc_tls SET v = v + 1 WHERE id = 1')
    const waiters = []
    for (let i = 0; i < 3; i++) {
      const w = await connect(proxy.port, 'bitsql')
      waiters.push(w)
      // a reply far larger than the TLS write buffer once the lock is free
      batch(w, "UPDATE dbo.disc_tls SET v = v + 10 WHERE id = 1; SELECT REPLICATE(CONVERT(varchar(max), 'x'), 4000000) AS big").catch(() => {})
    }
    await sleep(100)
    for (const c of [holder, ...waiters]) c.socket?.destroy()
    await sleep(600)
    // the server is still up and the holder's lock is gone
    const rows = await batch(setup, 'SET LOCK_TIMEOUT 0; UPDATE dbo.disc_tls SET v = 1 WHERE id = 1; SELECT v FROM dbo.disc_tls')
    assert.deepEqual(rows, [[1]])
  }
  // and still accepts new sessions
  const fresh = await connect(s.port, 'bitsql', 5000)
  t.after(() => fresh.close())
  assert.deepEqual(await batch(fresh, 'SELECT 1'), [[1]])
})
