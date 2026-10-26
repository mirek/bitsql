// TLS for TDS 7.x (MS-TDS 2.2.6.5 / 3.3.4), as src/host/tls.mbt: after a
// PRELOGIN exchange that negotiated encryption, the client sends its TLS
// handshake records inside PRELOGIN packets and expects one PRELOGIN message
// back per flight. Once the handshake completes, TLS records travel bare on
// the socket. With login-only encryption (ENCRYPT_OFF) TLS ends right after
// LOGIN7. The engine never sees ciphertext: it asks for TLS with StartTls
// and EndTls, and the host feeds it the plaintext.
import { Duplex } from 'node:stream'
import { TLSSocket, createSecureContext, type SecureContext } from 'node:tls'
import type { Socket } from 'node:net'

const HEADER_LEN = 8
const PACKET_SIZE = 4096
const STATUS_EOM = 0x01
const PRELOGIN = 0x12
const MAX_MESSAGE = 64 * 1024 * 1024

/**
 * TLS 1.2 at most: SQL Server does TLS 1.3 only with TDS 8 (strict). Under
 * TDS 7 wrapping it would also break clients: TLS 1.3 session tickets follow
 * the client's Finished, after the client has stopped unwrapping PRELOGIN.
 */
export function serverContext(key: string | Buffer, cert: string | Buffer): SecureContext {
  return createSecureContext({ key, cert, maxVersion: 'TLSv1.2' })
}

/** TDS message reassembly (`@tds.Reassembler`). */
class Reassembler {
  private pending = Buffer.alloc(0)
  private body: Buffer[] = []
  private bodyLength = 0
  private type = -1

  push(chunk: Buffer): { type: number; payload: Buffer }[] {
    const data = this.pending.length ? Buffer.concat([this.pending, chunk]) : chunk
    const out: { type: number; payload: Buffer }[] = []
    let pos = 0
    while (data.length - pos >= HEADER_LEN) {
      const type = data[pos]
      const status = data[pos + 1]
      const len = data.readUInt16BE(pos + 2)
      if (len < HEADER_LEN) throw new Error(`packet length ${len} shorter than header`)
      if (data.length - pos < len) break
      if (this.type >= 0 && this.type !== type) throw new Error('packet type changed mid-message')
      this.type = type
      this.body.push(data.subarray(pos + HEADER_LEN, pos + len))
      this.bodyLength += len - HEADER_LEN
      if (this.bodyLength > MAX_MESSAGE) throw new Error(`message exceeds ${MAX_MESSAGE} bytes`)
      pos += len
      if (status & STATUS_EOM) {
        out.push({ type, payload: Buffer.concat(this.body) })
        this.body = []
        this.bodyLength = 0
        this.type = -1
      }
    }
    this.pending = Buffer.from(data.subarray(pos))
    return out
  }
}

/** `@tds.frame(Prelogin, payload, first_packet_id=0)`. */
function frame(payload: Buffer): Buffer {
  const room = PACKET_SIZE - HEADER_LEN
  const packets: Buffer[] = []
  let id = 0
  for (let pos = 0; ; id++) {
    const n = Math.min(room, payload.length - pos)
    const last = pos + n >= payload.length
    const header = Buffer.alloc(HEADER_LEN)
    header[0] = PRELOGIN
    header[1] = last ? STATUS_EOM : 0
    header.writeUInt16BE(n + HEADER_LEN, 2)
    header[6] = id % 256
    packets.push(header, payload.subarray(pos, pos + n))
    pos += n
    if (last) break
  }
  return Buffer.concat(packets)
}

/**
 * The socket side of one TLS session, handed to Node's TLS as its
 * transport. While `wrapped`, incoming bytes are PRELOGIN packets whose
 * payloads are TLS records, and outgoing records are batched per flight into
 * one PRELOGIN message (sent once the TLS engine has written everything it
 * produced for the input it was given, and when the handshake completes).
 */
class Wire extends Duplex {
  wrapped = true
  private unwrap = new Reassembler()
  private flight: Buffer[] = []
  private flushScheduled = false

  constructor(private socket: Socket) {
    super()
  }

  feed(chunk: Buffer) {
    if (!this.wrapped) { this.push(chunk); return }
    for (const message of this.unwrap.push(chunk)) {
      if (message.type !== PRELOGIN) throw new Error('TLS handshake: expected a PRELOGIN packet')
      this.push(message.payload)
    }
  }

  sendFlight() {
    this.flushScheduled = false
    if (!this.flight.length) return
    const records = Buffer.concat(this.flight)
    this.flight = []
    // captured: SQL Server's handshake replies are PRELOGIN, EOM, packet id 0
    if (!this.socket.destroyed) this.socket.write(frame(records))
  }

  override _read() {}

  override _write(chunk: Buffer, _encoding: BufferEncoding, done: (error?: Error | null) => void) {
    if (this.wrapped) {
      this.flight.push(chunk)
      if (!this.flushScheduled) {
        this.flushScheduled = true
        setImmediate(() => { if (this.wrapped) this.sendFlight() })
      }
    } else if (!this.socket.destroyed) {
      this.socket.write(chunk)
    }
    done()
  }
}

/** One connection's TLS session (`run_tls`). */
export class TlsSession {
  private wire: Wire
  private tls: TLSSocket
  private inputOpen = true

  constructor(
    socket: Socket,
    context: SecureContext,
    deliver: (plaintext: Buffer) => void,
    fail: (error: Error) => void,
    /** EOF from the client while TLS is still the connection's mode. */
    ended: () => void,
  ) {
    this.wire = new Wire(socket)
    this.tls = new TLSSocket(this.wire, { isServer: true, secureContext: context })
    // Node reports 'secure' before its final flight (NewSessionTicket,
    // ChangeCipherSpec, Finished) reaches the transport; that flight is still
    // wrapped, so the switch to bare records waits until it has been written.
    this.tls.on('secure', () => setImmediate(() => {
      this.wire.sendFlight()
      this.wire.wrapped = false
    }))
    this.tls.on('data', deliver)
    this.tls.on('error', fail)
    this.tls.on('end', () => { if (this.inputOpen) ended() })
  }

  /** Raw socket bytes. Throws on a malformed handshake packet. */
  feed(chunk: Buffer) {
    if (this.inputOpen) this.wire.feed(chunk)
  }

  write(plaintext: Buffer) {
    this.tls.write(plaintext)
  }

  /**
   * EndTls (login-only encryption): no more input reaches TLS, and later
   * socket bytes are plaintext. Ciphertext already being written still
   * reaches the socket.
   */
  end() {
    this.inputOpen = false
  }
}
