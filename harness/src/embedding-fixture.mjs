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
    let response = { body: '{}' }
    server = https.createServer({ key: await readFile(key), cert: await readFile(cert) }, (req, res) => {
      const chunks = []
      req.on('data', b => chunks.push(b))
      req.on('end', () => {
        requests.push({ method: req.method, url: req.url, headers: { ...req.headers, host: '{authority}' },
          body: Buffer.concat(chunks).toString('utf8') })
        res.writeHead(response.status ?? 200, { 'Content-Type': response.contentType ?? 'application/json',
          'Connection': 'close', ...response.headers })
        res.end(typeof response.body === 'string' ? response.body : JSON.stringify(response.body))
      })
    })
    await new Promise((ok, fail) => { server.once('error', fail); server.listen(0, host, ok) })
    return {
      cert, port: server.address().port, requests,
      setResponse(value) { requests.length = 0; response = value },
      async close() {
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
