// The TypeScript host, as src/host/main.mbt: moves bytes between sockets and
// the engine, fires timers, runs outbound HTTP. Knows nothing about SQL or TDS
// beyond the TLS wrapping (tls.ts).
import { createServer, type Server, type Socket } from 'node:net'
import { appendFileSync, writeFileSync } from 'node:fs'
import type { SecureContext } from 'node:tls'
import { Engine, encodeEvent, eventLogHeader, type Input, type Output } from './engine'
import { performHttp } from './http'
import { clockTicks, cpuCount, cpuMicros, memoryKb, nowTicks, systemFacts } from './system'
import { TlsSession, serverContext } from './tls'

export interface HostOptions {
  host: string
  port: number
  databases: string[]
  autoCreateDatabases: boolean
  /** Negative: the engine's default. */
  maxRequestWork: bigint
  /** PEM key and certificate; `undefined` uses the built-in pair, `false` refuses encryption. */
  tls: { key: string | Buffer; cert: string | Buffer } | false | undefined
  /** PEM trust roots for outbound HTTPS; default: Node's bundled roots. */
  httpCa: Buffer | undefined
  /** Append every engine event to this file for `replay`. */
  record: string | undefined
  log: (line: string) => void
}

type Mode = { kind: 'plain' } | { kind: 'pending' } | { kind: 'tls'; session: TlsSession }

interface Conn {
  socket: Socket
  mode: Mode
}

export class Host {
  private engine!: Engine
  private server!: Server
  private context: SecureContext | undefined
  private conns = new Map<number, Conn>()
  // pending timers: id → generation (a re-set or cancel invalidates it)
  private timers = new Map<number, number>()
  private timerHandles = new Set<NodeJS.Timeout>()
  private timerGeneration = 0
  private http = new Map<number, AbortController>()
  private queue: Input[] = []
  private busy = false
  private nextId = 0
  private closed = false

  /** `fatal`: the engine failed (a trap such as stack exhaustion); its state is no longer trustworthy. */
  constructor(private options: HostOptions, private module: WebAssembly.Module, private fatal: (error: Error) => void) {}

  async listen(): Promise<{ host: string; port: number }> {
    const { options } = this
    const seed = nowTicks()
    this.engine = new Engine(this.module, {
      seed,
      maxRequestWork: options.maxRequestWork,
      autoCreateDatabases: options.autoCreateDatabases,
      tls: options.tls !== false,
      databases: options.databases,
    })
    if (options.tls !== false) {
      const { key, cert } = options.tls ?? this.engine.tlsIdentity()
      this.context = serverContext(key, cert)
    }
    if (options.record) writeFileSync(options.record, eventLogHeader(seed), { flag: 'a' })
    const now = nowTicks()
    this.handle({ kind: 'monitoringStarted', cpus: cpuCount(), memoryKb: memoryKb() }, now)
    this.handle({ kind: 'systemFacts', facts: systemFacts() }, now)

    this.server = createServer({ noDelay: true }, socket => this.accept(socket))
    await new Promise<void>((resolve, reject) => {
      this.server.once('error', reject)
      this.server.listen(options.port, options.host, () => { this.server.off('error', reject); resolve() })
    })
    const address = this.server.address()
    return { host: options.host, port: typeof address === 'object' && address ? address.port : options.port }
  }

  /** Stops listening and drops every connection, timer and HTTP call. */
  close(): Promise<void> {
    if (this.closed) return Promise.resolve()
    this.closed = true
    for (const conn of this.conns.values()) conn.socket.destroy()
    this.conns.clear()
    for (const handle of this.timerHandles) clearTimeout(handle)
    this.timerHandles.clear()
    for (const controller of this.http.values()) controller.abort()
    this.http.clear()
    return new Promise(resolve => this.server.close(() => resolve()))
  }

  version(): string {
    return this.engine.version()
  }

  private handle(input: Input, now: bigint): Output[] {
    const event = encodeEvent(input, now)
    if (this.options.record) appendFileSync(this.options.record, event)
    return this.engine.handle(event)
  }

  private accept(socket: Socket) {
    if (this.closed) { socket.destroy(); return }
    const id = ++this.nextId
    const conn: Conn = { socket, mode: { kind: 'plain' } }
    this.conns.set(id, conn)
    socket.on('error', () => socket.destroy())
    socket.on('close', () => {
      this.conns.delete(id)
      if (conn.mode.kind === 'tls') conn.mode.session.end()
      if (!this.closed) this.submit({ kind: 'closed', id })
    })
    this.submit({ kind: 'connected', id })
    socket.on('data', (chunk: Buffer) => {
      const mode = conn.mode
      if (mode.kind === 'plain') {
        this.submit({ kind: 'received', id, bytes: chunk })
      } else if (mode.kind === 'tls') {
        this.feed(id, socket, mode.session, chunk)
      } else if (this.context) {
        const session = new TlsSession(
          socket,
          this.context,
          plaintext => this.submit({ kind: 'received', id, bytes: plaintext }),
          error => {
            this.options.log(`connection ${id}: TLS: ${error.message}`)
            socket.destroy()
          },
          // EOF: unless login-only TLS ended, the session is over
          () => { if (conn.mode.kind === 'tls') socket.end() },
        )
        conn.mode = { kind: 'tls', session }
        this.feed(id, socket, session, chunk)
      } else {
        socket.destroy()
      }
    })
  }

  private feed(id: number, socket: Socket, session: TlsSession, chunk: Buffer) {
    try {
      session.feed(chunk)
    } catch (error) {
      this.options.log(`connection ${id}: TLS: ${(error as Error).message}`)
      socket.destroy()
    }
  }

  // One input at a time through the engine and its outputs, in arrival order.
  private submit(input: Input) {
    this.queue.push(input)
    if (this.busy) return
    this.busy = true
    try {
      for (let next; (next = this.queue.shift()) !== undefined;) this.process(next)
    } catch (error) {
      // Never surfaces as a socket or TLS error: the whole server is gone,
      // as when the native host crashes.
      this.closed = true
      this.fatal(error as Error)
    } finally {
      this.busy = false
    }
  }

  private process(input: Input) {
    if (this.closed) return
    const now = nowTicks()
    const before = cpuMicros()
    let outputs = this.handle(input, now)
    let charge = input.kind === 'received' || input.kind === 'timerFired' || input.kind === 'httpCompleted'
      ? { id: input.id, cpu: cpuMicros() - before, now }
      : undefined
    // Each round: measurement samples are stamped before any socket I/O (no
    // write is charged to the measured statement), the replies go out, then
    // the engine's bookkeeping (CPU charges, sample handling, which may
    // resume parked requests: the next round's outputs).
    for (;;) {
      const samples: [number, bigint][] = []
      for (const o of outputs) if (o.kind === 'sample') samples.push([o.id, clockTicks()])
      for (const o of outputs) this.apply(o)
      if (charge) {
        this.handle({ kind: 'cpuUsed', id: charge.id, cpu: charge.cpu }, charge.now)
        charge = undefined
      }
      if (!samples.length) break
      outputs = []
      for (const [id, sampled] of samples) {
        const start = cpuMicros()
        outputs.push(...this.handle({ kind: 'measured', id, cpu: 0n }, sampled))
        this.handle({ kind: 'cpuUsed', id, cpu: cpuMicros() - start }, sampled)
      }
    }
  }

  private apply(o: Output) {
    switch (o.kind) {
      case 'sample': case 'yield': break
      case 'cancelTimer': this.timers.delete(o.id); break
      case 'send': {
        const conn = this.conns.get(o.id)
        if (!conn) break
        if (conn.mode.kind === 'tls') conn.mode.session.write(o.bytes)
        else conn.socket.write(o.bytes)
        break
      }
      case 'close': {
        const conn = this.conns.get(o.id)
        if (!conn) break
        this.conns.delete(o.id)
        conn.socket.end()
        break
      }
      case 'startTls': {
        const conn = this.conns.get(o.id)
        if (conn) conn.mode = { kind: 'pending' }
        break
      }
      case 'endTls': {
        const conn = this.conns.get(o.id)
        if (!conn) break
        if (conn.mode.kind === 'tls') conn.mode.session.end()
        conn.mode = { kind: 'plain' }
        break
      }
      case 'log': this.options.log(o.text); break
      case 'setTimer': {
        const generation = ++this.timerGeneration
        this.timers.set(o.id, generation)
        const handle = setTimeout(() => {
          this.timerHandles.delete(handle)
          if (this.timers.get(o.id) !== generation) return
          this.timers.delete(o.id)
          this.submit({ kind: 'timerFired', id: o.id })
        }, o.ms)
        this.timerHandles.add(handle)
        break
      }
      case 'fetchHttp': {
        const controller = new AbortController()
        this.http.set(o.generation, controller)
        void performHttp(o.request, this.options.httpCa, controller.signal).then(result => {
          if (controller.signal.aborted) return
          this.http.delete(o.generation)
          this.submit({ kind: 'httpCompleted', id: o.id, generation: o.generation, result })
        })
        break
      }
      case 'cancelHttp': {
        this.http.get(o.generation)?.abort()
        this.http.delete(o.generation)
        break
      }
    }
  }
}
