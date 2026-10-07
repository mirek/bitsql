// Controlled HTTPS embedding endpoint. SQL expectations come from the oracle,
// while these response bodies are deliberately chosen test inputs.
import https from 'node:https'
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { outDir } from './env.mjs'
const exec = promisify(execFile)

export async function embeddingFixture(host = '127.0.0.1') {
  await mkdir(outDir, { recursive: true })
  const dir = await mkdtemp(join(outDir, 'embedding-fixture-'))
  let server
  try {
    const key = join(dir, 'key.pem'), cert = join(dir, 'cert.crt')
    await exec('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
      '-out', cert, '-days', '1', '-subj', '/CN=bitsql-embedding-fixture', '-addext',
      `subjectAltName=IP:${host},IP:127.0.0.1,DNS:localhost,DNS:bitsql-embedding.test`])
    const requests = []
    const timers = new Set()
    const held = []
    let paused = false
    let response = { body: '{}' }
    server = https.createServer({ key: await readFile(key), cert: await readFile(cert) }, (req, res) => {
      const chunks = []
      req.on('data', b => chunks.push(b))
      req.on('end', () => {
        requests.push({ method: req.method, url: req.url, headers: { ...req.headers, host: '{authority}' },
          body: Buffer.concat(chunks).toString('utf8') })
        const selected = response
        const reply = () => {
          if (res.destroyed) return
          res.writeHead(selected.status ?? 200, { 'Content-Type': selected.contentType ?? 'application/json',
            'Connection': 'close', ...selected.headers })
          res.end(typeof selected.body === 'string' ? selected.body : JSON.stringify(selected.body))
        }
        if (paused) held.push(reply)
        else if (selected.delayMs) {
          const timer = setTimeout(() => { timers.delete(timer); reply() }, selected.delayMs)
          timers.add(timer)
        } else reply()
      })
    })
    await new Promise((ok, fail) => { server.once('error', fail); server.listen(0, host, ok) })
    return {
      cert, port: server.address().port, requests,
      setResponse(value) { requests.length = 0; response = value; paused = Boolean(value.hold) },
      release() { paused = false; for (const reply of held.splice(0)) reply() },
      async close() {
        for (const timer of timers) clearTimeout(timer)
        timers.clear()
        held.length = 0
        server.closeAllConnections()
        await new Promise(ok => server.close(ok))
        await rm(dir, { recursive: true, force: true })
      },
    }
  } catch (e) {
    server?.closeAllConnections(); server?.close()
    await rm(dir, { recursive: true, force: true })
    throw e
  }
}
