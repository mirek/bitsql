///|
/// TDS packet header length in bytes.
pub const HEADER_LEN : Int = 8

///|
/// Default packet size before LOGIN7 negotiates another.
pub const DEFAULT_PACKET_SIZE : Int = 4096

///|
/// Packet type byte (MS-TDS 2.2.3.1.1).
pub(all) enum PacketType {
  SqlBatch // 0x01
  Rpc // 0x03
  TabularResult // 0x04
  Attention // 0x06
  BulkLoad // 0x07
  TransactionManager // 0x0E
  Login7 // 0x10
  Sspi // 0x11
  Prelogin // 0x12
  Other(Int)
} derive(Debug, Eq)

///|
pub fn PacketType::from_byte(b : Int) -> PacketType {
  match b {
    0x01 => SqlBatch
    0x03 => Rpc
    0x04 => TabularResult
    0x06 => Attention
    0x07 => BulkLoad
    0x0E => TransactionManager
    0x10 => Login7
    0x11 => Sspi
    0x12 => Prelogin
    n => Other(n)
  }
}

///|
pub fn PacketType::to_byte(self : PacketType) -> Int {
  match self {
    SqlBatch => 0x01
    Rpc => 0x03
    TabularResult => 0x04
    Attention => 0x06
    BulkLoad => 0x07
    TransactionManager => 0x0E
    Login7 => 0x10
    Sspi => 0x11
    Prelogin => 0x12
    Other(n) => n
  }
}

///|
pub const STATUS_EOM : Int = 0x01

///|
pub const STATUS_IGNORE : Int = 0x02

///|
pub const STATUS_RESET_CONNECTION : Int = 0x08

///|
/// One reassembled client message: all packets up to and including EOM.
pub(all) struct Message {
  ty : PacketType
  /// OR of every packet's status byte (IGNORE / RESETCONNECTION live here).
  status : Int
  payload : Bytes
} derive(Debug)

///|
/// Incremental, pure message reassembler. Feed raw socket chunks with
/// `push`; complete messages come out in order. Malformed framing raises.
pub struct Reassembler {
  pending : Buffer // bytes not yet forming a full packet
  body : Buffer // payload of the message in progress
  mut ty : Int // -1 when no message is in progress
  mut status : Int
  max_message : Int
}

///|
pub fn Reassembler::new(max_message? : Int = 64 * 1024 * 1024) -> Reassembler {
  { pending: Buffer(), body: Buffer(), ty: -1, status: 0, max_message, }
}

///|
pub fn Reassembler::push(
  self : Reassembler,
  chunk : BytesView,
) -> Array[Message] raise TdsError {
  self.pending.write_bytes(chunk)
  let out = []
  let data = self.pending.to_bytes()
  let mut pos = 0
  while data.length() - pos >= HEADER_LEN {
    let ty = data[pos].to_int()
    let status = data[pos + 1].to_int()
    let len = (data[pos + 2].to_int() << 8) | data[pos + 3].to_int()
    if len < HEADER_LEN {
      raise Malformed("packet length \{len} shorter than header")
    }
    if data.length() - pos < len {
      break
    }
    if self.ty >= 0 && self.ty != ty {
      raise Malformed("packet type changed mid-message")
    }
    self.ty = ty
    self.status = self.status | status
    self.body.write_bytes(data[pos + HEADER_LEN:pos + len])
    if self.body.length() > self.max_message {
      raise Malformed("message exceeds \{self.max_message} bytes")
    }
    pos += len
    if (status & STATUS_EOM) != 0 {
      out.push({
        ty: PacketType::from_byte(ty),
        status: self.status,
        payload: self.body.to_bytes(),
      })
      self.body.reset()
      self.ty = -1
      self.status = 0
    }
  }
  self.pending.reset()
  self.pending.write_bytes(data[pos:])
  out
}

///|
/// Splits a server message into packets of at most `packet_size` bytes,
/// setting EOM on the last one. Packet ids count from `first_packet_id`
/// (1; SQL Server's TLS handshake replies start at 0) and wrap at 256.
pub fn frame(
  ty : PacketType,
  payload : BytesView,
  packet_size? : Int = DEFAULT_PACKET_SIZE,
  spid? : Int = 0,
  first_packet_id? : Int = 1,
) -> Bytes {
  let room = packet_size - HEADER_LEN
  let w = Writer::new(size_hint=payload.length() + HEADER_LEN)
  let mut pos = 0
  let mut id = first_packet_id
  while true {
    let n = @cmp.minimum(room, payload.length() - pos)
    let last = pos + n >= payload.length()
    w.u8(ty.to_byte())
    w.u8(if last { STATUS_EOM } else { 0 })
    w.u16be(n + HEADER_LEN)
    w.u16be(spid)
    w.u8(id % 256)
    w.u8(0)
    w.bytes(payload[pos:pos + n])
    pos += n
    id += 1
    if last {
      break
    }
  }
  w.to_bytes()
}
