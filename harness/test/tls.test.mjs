// TLS: tedious encrypt true/false, and login-only encryption (PRELOGIN
// ENCRYPT_OFF, what tiberius/Prisma's CLI sends for `encrypt=false`): TLS
// for LOGIN7 only, then plaintext. Expectations follow captures from SQL
// Server 2025 (tedious skill, bitsql findings 2026-10-04).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import tls from 'node:tls'
import { Duplex } from 'node:stream'
import { createRequire } from 'node:module'
import { Request } from 'tedious'
import { connect, close } from '../src/client.mjs'
import { server } from './support.mjs'

const require = createRequire(import.meta.url)
const Login7Payload = require('tedious/lib/login7-payload.js')

async function scalar(connection, sql) {
  let value
  await new Promise((resolve, reject) => {
    const request = new Request(sql, error => error ? reject(error) : resolve())
    request.on('row', row => { value = row[0].value })
    connection.execSqlBatch(request)
  })
  return value
}

const encryptOption = 'SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID'

for (const encrypt of [true, false]) {
  test(`tedious encrypt:${encrypt} logs in; dm_exec_connections.encrypt_option`, async t => {
    const s = await server(t)
    const connection = await connect({ ...s.config, options: { ...s.config.options, encrypt } })
    t.after(() => close(connection))
    assert.equal(await scalar(connection, encryptOption), encrypt ? 'TRUE' : 'FALSE')
  })
}

function packet(type, payload) {
  const header = Buffer.from([type, 1, 0, 0, 0, 0, 1, 0])
  header.writeUInt16BE(8 + payload.length, 2)
  return Buffer.concat([header, payload])
}

// Reads whole TDS messages (until EOM) from a byte stream.
function messageReader(source) {
  let buffered = Buffer.alloc(0)
  let parts = []
  const waiting = []
  const ready = []
  source.on('data', data => {
    buffered = Buffer.concat([buffered, data])
    while (buffered.length >= 8 && buffered.length >= buffered.readUInt16BE(2)) {
      const length = buffered.readUInt16BE(2)
      const header = buffered.subarray(0, 8)
      parts.push(buffered.subarray(8, length))
      buffered = buffered.subarray(length)
      if (header[1] & 1) {
        const message = { type: header[0], packetId: header[6], payload: Buffer.concat(parts) }
        parts = []
        if (waiting.length) waiting.shift()(message)
        else ready.push(message)
      }
    }
  })
  return () => ready.length ? Promise.resolve(ready.shift()) : new Promise(resolve => waiting.push(resolve))
}

test('login-only TLS (PRELOGIN ENCRYPT_OFF): LOGIN7 encrypted, then plaintext', async t => {
  const s = await server(t)
  const socket = net.connect(s.port, s.host)
  t.after(() => socket.destroy())
  await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject) })
  const next = messageReader(socket)

  // VERSION, ENCRYPTION = OFF
  socket.write(packet(0x12, Buffer.from([0, 0, 11, 0, 6, 1, 0, 17, 0, 1, 0xff, 0x0c, 0, 0, 0, 0, 0, 0x00])))
  const prelogin = await next()
  assert.equal(prelogin.type, 0x04)
  const p = prelogin.payload
  let encryption
  for (let i = 0; p[i] !== 0xff; i += 5) if (p[i] === 1) encryption = p[p.readUInt16BE(i + 1)]
  assert.equal(encryption, 0x00, 'server answers ENCRYPT_OFF')

  // Handshake records travel in PRELOGIN packets; each server flight is one
  // PRELOGIN message whose packet ids start at 0.
  const flights = []
  let wrapped = true
  const wire = new Duplex({
    read() {},
    write(chunk, _encoding, done) { socket.write(wrapped ? packet(0x12, chunk) : chunk); done() },
  })
  const secure = tls.connect({ socket: wire, rejectUnauthorized: false, maxVersion: 'TLSv1.2' })
  const pump = (async () => {
    for (;;) {
      const message = await next()
      if (message.type !== 0x12) return message
      flights.push(message)
      wire.push(message.payload)
    }
  })()
  await new Promise((resolve, reject) => { secure.once('secureConnect', resolve); secure.once('error', reject) })
  wrapped = false
  assert.ok(flights.length >= 2)
  for (const f of flights) assert.equal(f.packetId, 0)
  assert.equal(secure.getProtocol(), 'TLSv1.2')

  // LOGIN7 through TLS; after it the client switches back to the raw socket
  const login = new Login7Payload({ tdsVersion: 0x74000004, packetSize: 4096, clientProgVer: 0, clientPid: 1, connectionId: 0, clientTimeZone: 0, clientLcid: 0x409 })
  Object.assign(login, { userName: 'sa', password: process.env.BITSQL_TEST_PASSWORD ?? 'bitsql', hostname: 'h', appName: 'tls-test', serverName: s.host, language: 'us_english', database: 'master', libraryName: 'raw' })
  secure.write(packet(0x10, login.toBuffer()))
  const loginReply = await pump
  assert.equal(loginReply.type, 0x04, 'LOGIN7 response arrives in plaintext')
  assert.ok(loginReply.payload.includes(0xad), 'LOGINACK')

  // plaintext SQL batch; encrypt_option is FALSE for login-only encryption
  const all = Buffer.from([0x16, 0, 0, 0, 0x12, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])
  socket.write(packet(0x01, Buffer.concat([all, Buffer.from(encryptOption, 'utf16le')])))
  const reply = await next()
  assert.equal(reply.type, 0x04)
  assert.ok(reply.payload.includes(Buffer.from('FALSE', 'utf16le')))
  assert.ok(!reply.payload.includes(0xaa), 'no ERROR token')
})
