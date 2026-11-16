// A client that stops reading in the middle of a large reply, without
// closing, must stall only its own session (2026-11-16). Replies used to be
// written while the host held the engine lock, so once the stalled client's
// socket buffers filled, every other session waited until that write failed.
// The proxy below stops reading the server's side of one connection on
// demand, which is what a client blocked in its own code looks like.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { Connection, Request } from 'tedious'
import { server } from './support.mjs'

function stallingProxy(targetPort) {
  const sockets = new Set()
  const pairs = []
  const proxy = net.createServer(client => {
    const backend = net.connect(targetPort, '127.0.0.1')
    sockets.add(client); sockets.add(backend); pairs.push({ client, backend })
    client.pipe(backend)
    backend.pipe(client)
    client.on('error', () => backend.destroy())
    backend.on('error', () => client.destroy())
  })
  return new Promise(resolve => proxy.listen(0, '127.0.0.1', () => resolve({
    port: proxy.address().port,
    pairs,
    close: () => { for (const s of sockets) s.destroy(); proxy.close() },
  })))
}

function connect(port, encrypt, requestTimeout = 0) {
  return new Promise((resolve, reject) => {
    const c = new Connection({
      server: '127.0.0.1',
      authentication: { type: 'default', options: { userName: 'sa', password: 'bitsql' } },
      options: { port, encrypt, trustServerCertificate: true, database: 'master', requestTimeout, connectTimeout: 5000 },
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

for (const encrypt of [false, true]) {
  test(`a client that stops reading stalls only its own session (encrypt: ${encrypt})`, { timeout: 60000 }, async t => {
    const s = await server(t)
    const proxy = await stallingProxy(s.port)
    t.after(() => proxy.close())
    const stalled = await connect(proxy.port, encrypt)
    t.after(() => stalled.close())
    const { client, backend } = proxy.pairs[0]
    let received = 0
    backend.on('data', d => { received += d.length })
    // far more than the socket buffers hold; a pattern whose length divides
    // no buffer size, so a lost, repeated or reordered chunk shows
    const pattern = 'abcdefghijklm'
    const big = batch(stalled, `SELECT REPLICATE(CONVERT(varchar(max), '${pattern}'), 2300000) AS big`)
    // stop reading once the reply has started to arrive
    while (received === 0) await sleep(5)
    backend.unpipe()
    backend.pause()
    await sleep(500)
    // other sessions, new and existing, are served meanwhile
    const other = await connect(s.port, encrypt, 3000)
    t.after(() => other.close())
    for (let i = 0; i < 3; i++) assert.deepEqual(await batch(other, `SELECT ${i}`), [[i]])
    // the stalled client gets its whole reply once it reads again
    backend.pipe(client)
    const rows = await big
    assert.ok(rows[0][0] === pattern.repeat(2300000), 'reply arrives intact')
    assert.deepEqual(await batch(stalled, 'SELECT 1'), [[1]])
  })
}
