// Outbound HTTPS for embedding calls, as src/host/http.mbt: the exact
// captured request over TLS (Node's HTTP clients add headers such as
// Connection that SQL Server's embedding requests do not send).
import { connect, type TLSSocket } from 'node:tls'
import type { HttpRequest, HttpResult } from './engine'

const malformed = () => new Error('malformed HTTP response or URL')
const fatalUtf8 = new TextDecoder('utf-8', { fatal: true })

class SocketReader {
  private buffer = Buffer.alloc(0)
  private ended = false
  private failure: Error | undefined
  private wake: (() => void) | undefined

  constructor(socket: TLSSocket) {
    socket.on('data', (chunk: Buffer) => { this.buffer = Buffer.concat([this.buffer, chunk]); this.notify() })
    socket.on('end', () => { this.ended = true; this.notify() })
    socket.on('close', () => { this.ended = true; this.notify() })
    socket.on('error', error => { this.failure = error; this.notify() })
  }

  private notify() { const wake = this.wake; this.wake = undefined; wake?.() }

  private async more(): Promise<boolean> {
    if (this.failure) throw this.failure
    if (this.ended) return false
    await new Promise<void>(resolve => { this.wake = resolve })
    if (this.failure) throw this.failure
    return true
  }

  async readUntil(delimiter: string): Promise<string | undefined> {
    for (;;) {
      const at = this.buffer.indexOf(delimiter)
      if (at >= 0) {
        const line = this.buffer.subarray(0, at)
        this.buffer = this.buffer.subarray(at + delimiter.length)
        return fatalUtf8.decode(line)
      }
      if (!(await this.more())) return undefined
    }
  }

  async readExactly(n: number): Promise<Buffer> {
    while (this.buffer.length < n) if (!(await this.more())) throw new Error('unexpected end of HTTP response')
    const out = this.buffer.subarray(0, n)
    this.buffer = this.buffer.subarray(n)
    return out
  }

  async readAll(): Promise<Buffer> {
    while (await this.more());
    const out = this.buffer
    this.buffer = Buffer.alloc(0)
    return out
  }
}

function parseInt10(text: string, base = 10): number {
  const t = text.trim()
  if (!(base === 16 ? /^[0-9a-fA-F]+$/ : /^[+-]?\d+$/).test(t)) throw malformed()
  return Number.parseInt(t, base)
}

async function attempt(request: HttpRequest, ca: Buffer | undefined, signal: AbortSignal): Promise<HttpResult> {
  const { url } = request
  if (!url.startsWith('https://') || /[\r\n#]/.test(url)) throw malformed()
  const rest = url.slice(8)
  let cut = rest.search(/[/?]/)
  if (cut < 0) cut = rest.length
  const authority = rest.slice(0, cut)
  const tail = rest.slice(cut)
  const path = tail === '' ? '/' : tail.startsWith('?') ? '/' + tail : tail
  const match = authority.match(/^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/)
  if (!match) throw malformed()
  const host = match[1].replace(/^\[|\]$/g, '')
  const socket = connect({ host, port: match[2] ? Number(match[2]) : 443, servername: /^[\d.:]+$/.test(host) ? undefined : host, ca })
  const abort = () => socket.destroy(new Error('cancelled'))
  signal.addEventListener('abort', abort)
  try {
    const reader = new SocketReader(socket)
    const body = Buffer.from(request.body, 'utf8')
    let head = `POST ${path} HTTP/1.1\r\n`
    for (const [key, value] of request.headers) head += `${key}: ${value}\r\n`
    head += `Content-Length: ${body.length}\r\nHost: ${authority}\r\n\r\n`
    socket.write(Buffer.concat([Buffer.from(head, 'utf8'), body]))
    for (;;) {
      const statusLine = await reader.readUntil('\r\n')
      if (statusLine === undefined) throw malformed()
      const parts = statusLine.split(' ')
      if (parts.length < 2) throw malformed()
      const status = parseInt10(parts[1])
      const headers = new Map<string, string>()
      for (;;) {
        const line = await reader.readUntil('\r\n')
        if (line === undefined) throw malformed()
        if (line === '') break
        const colon = line.indexOf(':')
        if (colon < 0) throw malformed()
        headers.set(line.slice(0, colon).toLowerCase(), line.slice(colon + 1).trim())
      }
      if (status >= 100 && status < 200) continue
      const encoding = headers.get('content-encoding')
      if (encoding !== undefined && encoding !== 'identity') throw new Error(`HTTP content encoding ${encoding}`)
      let bytes: Buffer
      if (status === 204 || status === 304) {
        bytes = Buffer.alloc(0)
      } else if (headers.has('transfer-encoding')) {
        if (headers.get('transfer-encoding')!.toLowerCase() !== 'chunked') throw malformed()
        const chunks: Buffer[] = []
        for (;;) {
          const line = await reader.readUntil('\r\n')
          if (line === undefined) throw malformed()
          const n = parseInt10(line.split(';')[0], 16)
          if (n === 0) {
            for (;;) {
              const trailer = await reader.readUntil('\r\n')
              if (trailer === undefined) throw malformed()
              if (trailer === '') break
            }
            break
          }
          chunks.push(await reader.readExactly(n))
          if (!(await reader.readExactly(2)).equals(Buffer.from('\r\n'))) throw malformed()
        }
        bytes = Buffer.concat(chunks)
      } else if (headers.has('content-length')) {
        const n = parseInt10(headers.get('content-length')!)
        if (n < 0) throw malformed()
        bytes = await reader.readExactly(n)
      } else {
        bytes = await reader.readAll()
      }
      return { status, body: fatalUtf8.decode(bytes) }
    }
  } finally {
    signal.removeEventListener('abort', abort)
    socket.destroy()
  }
}

/** `perform_http`: retries listed statuses at once, transport errors become failures. */
export async function performHttp(request: HttpRequest, ca: Buffer | undefined, signal: AbortSignal): Promise<HttpResult> {
  try {
    for (let n = 0; ; n++) {
      const result = await attempt(request, ca, signal)
      if ('status' in result && n < request.retryCount && request.retryStatuses.includes(result.status)) continue
      return result
    }
  } catch (error) {
    return { failure: error instanceof Error ? error.message : String(error) }
  }
}
