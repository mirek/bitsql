// The engine compiled to WebAssembly GC (src/wasm). Inputs cross as
// event-log records (src/core/engine/event_log.mbt), so a host can also
// record them for `replay`; outputs use src/wasm's encoding.
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

/** 100 ns ticks from 0001-01-01 to 1970-01-01 (`@engine.UNIX_EPOCH_TICKS`). */
export const UNIX_EPOCH_TICKS = 621355968000000000n

export interface HttpRequest {
  url: string
  body: string
  headers: [string, string][]
  retryCount: number
  retryStatuses: number[]
}

export type HttpResult = { status: number; body: string } | { failure: string }

export type Input =
  | { kind: 'connected'; id: number }
  | { kind: 'received'; id: number; bytes: Uint8Array }
  | { kind: 'closed'; id: number }
  | { kind: 'timerFired'; id: number }
  | { kind: 'httpCompleted'; id: number; generation: number; result: HttpResult }
  | { kind: 'measured'; id: number; cpu: bigint }
  | { kind: 'monitoringStarted'; cpus: number; memoryKb: bigint }
  | { kind: 'cpuUsed'; id: number; cpu: bigint }
  | { kind: 'systemFacts'; facts: [string, bigint][] }

export type Output =
  | { kind: 'send'; id: number; bytes: Buffer }
  | { kind: 'close'; id: number }
  | { kind: 'setTimer'; id: number; ms: number }
  | { kind: 'cancelTimer'; id: number }
  | { kind: 'yield' }
  | { kind: 'log'; text: string }
  | { kind: 'startTls'; id: number }
  | { kind: 'endTls'; id: number }
  | { kind: 'sample'; id: number }
  | { kind: 'fetchHttp'; id: number; generation: number; request: HttpRequest }
  | { kind: 'cancelHttp'; id: number; generation: number }

export interface EngineConfig {
  seed: bigint
  /** Negative: the engine's default. */
  maxRequestWork: bigint
  autoCreateDatabases: boolean
  tls: boolean
  databases: string[]
}

interface Exports {
  memory: WebAssembly.Memory
  reserve(n: number): void
  create(n: number): void
  handle(n: number): number
  version(): number
  tls_identity(): number
}

let compiled: Promise<WebAssembly.Module> | undefined

/** Compiles the module once per process (~60 ms); every engine instantiates it. */
export function compileEngine(): Promise<WebAssembly.Module> {
  compiled ??= readFile(join(__dirname, '..', 'bitsql.wasm')).then(bytes => WebAssembly.compile(bytes))
  return compiled
}

const utf8 = new TextEncoder()
const fatalUtf8 = new TextDecoder('utf-8', { fatal: true })

class Writer {
  private parts: Buffer[] = []
  u8(v: number) { this.parts.push(Buffer.of(v)) }
  i32(v: number) { const b = Buffer.alloc(4); b.writeInt32LE(v); this.parts.push(b) }
  u32(v: number) { const b = Buffer.alloc(4); b.writeUInt32LE(v); this.parts.push(b) }
  i64(v: bigint) { const b = Buffer.alloc(8); b.writeBigInt64LE(BigInt.asIntN(64, v)); this.parts.push(b) }
  bytes(v: Uint8Array) { this.u32(v.length); this.parts.push(Buffer.from(v.buffer, v.byteOffset, v.length)) }
  string(v: string) { this.bytes(utf8.encode(v)) }
  raw(v: Uint8Array) { this.parts.push(Buffer.from(v.buffer, v.byteOffset, v.length)) }
  done() { return Buffer.concat(this.parts) }
}

class Reader {
  pos = 0
  constructor(private b: Buffer) {}
  get done() { return this.pos >= this.b.length }
  u8() { return this.b[this.pos++] }
  i32() { const v = this.b.readInt32LE(this.pos); this.pos += 4; return v }
  u32() { const v = this.b.readUInt32LE(this.pos); this.pos += 4; return v }
  bytes() { const n = this.u32(); const v = this.b.subarray(this.pos, this.pos + n); this.pos += n; return v }
  string() { return this.bytes().toString('utf8') }
}

/** The event-log file header (`@engine.encode_event_log_header`). */
export function eventLogHeader(seed: bigint): Buffer {
  const w = new Writer()
  w.raw(utf8.encode('BSQLEV1\n'))
  w.i64(seed)
  return w.done()
}

/** One event-log record (`@engine.encode_event`). */
export function encodeEvent(input: Input, now: bigint): Buffer {
  const w = new Writer()
  const tags = { connected: 0, received: 1, closed: 2, timerFired: 3, httpCompleted: 5, measured: 6, monitoringStarted: 7, cpuUsed: 8, systemFacts: 9 }
  w.u8(tags[input.kind])
  w.i64(now)
  w.i32(input.kind === 'monitoringStarted' ? input.cpus : input.kind === 'systemFacts' ? 0 : input.id)
  switch (input.kind) {
    case 'systemFacts':
      w.u32(input.facts.length)
      for (const [key, value] of input.facts) { w.string(key); w.i64(value) }
      break
    case 'monitoringStarted': w.i64(input.memoryKb); break
    case 'cpuUsed': case 'measured': w.i64(input.cpu); break
    case 'received': w.bytes(input.bytes); break
    case 'httpCompleted':
      w.i32(input.generation)
      if ('failure' in input.result) { w.i32(-1); w.string(input.result.failure) }
      else { w.i32(input.result.status); w.string(input.result.body) }
      break
  }
  return w.done()
}

function decodeOutputs(b: Buffer): Output[] {
  const r = new Reader(b)
  const out: Output[] = []
  while (!r.done) {
    const tag = r.u8()
    switch (tag) {
      case 0: { const id = r.i32(); out.push({ kind: 'send', id, bytes: Buffer.from(r.bytes()) }); break }
      case 1: out.push({ kind: 'close', id: r.i32() }); break
      case 2: { const id = r.i32(); out.push({ kind: 'setTimer', id, ms: r.i32() }); break }
      case 3: out.push({ kind: 'cancelTimer', id: r.i32() }); break
      case 4: out.push({ kind: 'yield' }); break
      case 5: out.push({ kind: 'log', text: r.string() }); break
      case 6: out.push({ kind: 'startTls', id: r.i32() }); break
      case 7: out.push({ kind: 'endTls', id: r.i32() }); break
      case 8: out.push({ kind: 'sample', id: r.i32() }); break
      case 9: {
        const id = r.i32()
        const generation = r.i32()
        const url = r.string()
        const body = r.string()
        const headers: [string, string][] = []
        for (let n = r.u32(); n > 0; n--) headers.push([r.string(), r.string()])
        const retryCount = r.i32()
        const retryStatuses: number[] = []
        for (let n = r.u32(); n > 0; n--) retryStatuses.push(r.i32())
        out.push({ kind: 'fetchHttp', id, generation, request: { url, body, headers, retryCount, retryStatuses } })
        break
      }
      case 10: { const id = r.i32(); out.push({ kind: 'cancelHttp', id, generation: r.i32() }); break }
      default: throw new Error(`bitsql: unknown engine output tag ${tag}`)
    }
  }
  return out
}

/** One engine instance: all databases and sessions of one server. */
export class Engine {
  private readonly w: Exports

  constructor(module: WebAssembly.Module, config: EngineConfig) {
    this.w = new WebAssembly.Instance(module, {}).exports as unknown as Exports
    const w = new Writer()
    w.i64(config.seed)
    w.i64(config.maxRequestWork)
    w.u8((config.autoCreateDatabases ? 1 : 0) | (config.tls ? 2 : 0))
    w.u32(config.databases.length)
    for (const name of config.databases) w.string(name)
    this.w.create(this.put(w.done()))
  }

  private put(b: Uint8Array): number {
    this.w.reserve(b.length)
    new Uint8Array(this.w.memory.buffer, 0, b.length).set(b)
    return b.length
  }

  // A view, valid until the next call (memory may grow).
  private result(n: number): Buffer {
    return Buffer.from(this.w.memory.buffer, 0, n)
  }

  /** Handles one encoded event (`encodeEvent`). */
  handle(event: Buffer): Output[] {
    return decodeOutputs(this.result(this.w.handle(this.put(event))))
  }

  version(): string {
    return fatalUtf8.decode(this.result(this.w.version()))
  }

  /** The built-in self-signed localhost key and certificate (PEM). */
  tlsIdentity(): { key: string; cert: string } {
    const r = new Reader(Buffer.from(this.result(this.w.tls_identity())))
    return { key: r.string(), cert: r.string() }
  }
}
