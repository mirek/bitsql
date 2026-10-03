///|
pub const DONE_FINAL : Int = 0x00

///|
pub const DONE_MORE : Int = 0x01

///|
pub const DONE_ERROR : Int = 0x02

///|
pub const DONE_INXACT : Int = 0x04

///|
pub const DONE_COUNT : Int = 0x10

///|
pub const DONE_ATTN : Int = 0x20

///|
pub const DONE_SRVERROR : Int = 0x100

///|
/// Which of the three DONE tokens to emit.
pub(all) enum DoneKind {
  Done // 0xFD
  DoneProc // 0xFE
  DoneInProc // 0xFF
} derive(Debug, Eq)

///|
pub fn write_done(
  w : Writer,
  kind : DoneKind,
  status : Int,
  cur_cmd : Int,
  row_count : Int64,
) -> Unit {
  w.u8(
    match kind {
      Done => 0xFD
      DoneProc => 0xFE
      DoneInProc => 0xFF
    },
  )
  w.u16le(status)
  w.u16le(cur_cmd)
  w.i64le(row_count)
}

///|
/// ERROR (0xAA) or INFO (0xAB) token.
pub fn write_message(
  w : Writer,
  is_error~ : Bool,
  number~ : Int,
  state~ : Int,
  class~ : Int,
  message~ : String,
  server~ : String,
  procedure~ : String,
  line~ : Int,
) -> Unit {
  let body = Writer::new()
  body.i32le(number)
  body.u8(state)
  body.u8(class)
  body.us_varchar(message)
  body.b_varchar(server)
  body.b_varchar(procedure)
  body.i32le(line)
  w.u8(if is_error { 0xAA } else { 0xAB })
  w.u16le(body.length())
  w.bytes(body.to_bytes())
}

///|
/// Server-to-client TDS 7.4 version for LOGINACK.
pub const TDS_74 : Int64 = 0x74000004

///|
pub fn write_loginack(
  w : Writer,
  tds_version~ : Int64,
  prog_name~ : String,
  version~ : (Int, Int, Int, Int),
) -> Unit {
  let body = Writer::new()
  body.u8(1) // SQL_TSQL
  body.u32be(tds_version)
  body.b_varchar(prog_name)
  let (major, minor, build_hi, build_lo) = version
  body.u8(major)
  body.u8(minor)
  body.u8(build_hi)
  body.u8(build_lo)
  w.u8(0xAD)
  w.u16le(body.length())
  w.bytes(body.to_bytes())
}

///|
/// ENVCHANGE kinds the server emits.
pub(all) enum EnvChange {
  Database(String, String) // new, old
  Language(String, String)
  PacketSize(Int, Int) // sent as strings on the wire
  Collation(Bytes, Bytes) // raw 5-byte collations
  BeginTransaction(UInt64)
  CommitTransaction(UInt64)
  RollbackTransaction(UInt64)
  ResetConnectionAck
} derive(Debug, Eq)

///|
pub fn write_envchange(w : Writer, e : EnvChange) -> Unit {
  let body = Writer::new()
  match e {
    Database(n, o) => {
      body.u8(1)
      body.b_varchar(n)
      body.b_varchar(o)
    }
    Language(n, o) => {
      body.u8(2)
      body.b_varchar(n)
      body.b_varchar(o)
    }
    PacketSize(n, o) => {
      body.u8(4)
      body.b_varchar(n.to_string())
      body.b_varchar(o.to_string())
    }
    Collation(n, o) => {
      body.u8(7)
      body.b_varbyte(n)
      body.b_varbyte(o)
    }
    BeginTransaction(d) => {
      body.u8(8)
      body.u8(8)
      body.u64le(d)
      body.u8(0)
    }
    CommitTransaction(d) => {
      body.u8(9)
      body.u8(0)
      body.u8(8)
      body.u64le(d)
    }
    RollbackTransaction(d) => {
      body.u8(10)
      body.u8(0)
      body.u8(8)
      body.u64le(d)
    }
    ResetConnectionAck => {
      body.u8(18)
      body.u8(0)
      body.u8(0)
    }
  }
  w.u8(0xE3)
  w.u16le(body.length())
  w.bytes(body.to_bytes())
}

///|
pub const COL_NULLABLE : Int = 0x0001

///|
pub const COL_CASE_SENSITIVE : Int = 0x0002

///|
pub const COL_UPDATEABLE_UNKNOWN : Int = 0x0008

///|
pub const COL_IDENTITY : Int = 0x0010

///|
pub const COL_COMPUTED : Int = 0x0020

///|
pub(all) struct Column {
  name : String
  type_info : TypeInfo
  /// COLMETADATA flags word (COL_* bits). SQL Server sets usUpdateable and
  /// fComputed in ways that only captures reveal; the binder decides.
  flags : Int
  user_type : Int
} derive(Debug, Eq)

///|
pub fn write_colmetadata(w : Writer, cols : ArrayView[Column]) -> Unit {
  w.u8(0x81)
  w.u16le(cols.length())
  for c in cols {
    w.u32le(c.user_type.to_int64())
    w.u16le(c.flags)
    write_type_info(w, c.type_info)
    // TableName of text/ntext/image columns: no parts (expressions;
    // tedious reads and ignores it)
    if c.type_info.is_lob() {
      w.u8(0)
    }
    w.b_varchar(c.name)
  }
}

///|
pub fn write_row(
  w : Writer,
  cols : ArrayView[Column],
  values : ArrayView[WireValue],
) -> Unit raise TdsError {
  if cols.length() != values.length() {
    raise Malformed(
      "row has \{values.length()} values for \{cols.length()} columns",
    )
  }
  w.u8(0xD1)
  for i in 0..<cols.length() {
    write_value(w, cols[i].type_info, values[i])
  }
}

///|
pub fn write_return_status(w : Writer, status : Int) -> Unit {
  w.u8(0x79)
  w.i32le(status)
}

///|
pub fn write_return_value(
  w : Writer,
  ordinal~ : Int,
  name~ : String,
  udf~ : Bool,
  type_info~ : TypeInfo,
  value~ : WireValue,
) -> Unit raise TdsError {
  w.u8(0xAC)
  w.u16le(ordinal)
  w.b_varchar(name)
  w.u8(if udf { 0x02 } else { 0x01 })
  w.u32le(0)
  w.u16le(COL_NULLABLE)
  write_type_info(w, type_info)
  write_value(w, type_info, value)
}

///|
/// SQL Server CurCmd values used in DONE tokens.
pub const CMD_SELECT : Int = 0xC1

///|
pub const CMD_INSERT : Int = 0xC3

///|
pub const CMD_DELETE : Int = 0xC4

///|
pub const CMD_UPDATE : Int = 0xC5

///|
pub const CMD_EXECUTE : Int = 0xE0

///|
pub const CMD_CONDITIONAL : Int = 0xC0

///|
/// ORDER (0xA9): 1-based projected ordinals of the ORDER BY keys, 0 for a
/// key that is not projected. Sent between COLMETADATA and the first ROW.
/// Emission rules are subtle (msduck docs/order-token.md); the binder decides.
pub fn write_order(w : Writer, ordinals : ArrayView[Int]) -> Unit {
  w.u8(0xA9)
  w.u16le(ordinals.length() * 2)
  for o in ordinals {
    w.u16le(o)
  }
}

///|
/// NBCROW (0xD2): null bitmap (bit i set = column i NULL) followed by the
/// non-null values. SQL Server sends it only when it is smaller than ROW:
/// see `nbcrow_is_smaller` (captured: smoke/rpc-null-params uses NBCROW,
/// smoke/multiple-sets with an equal size uses ROW).
pub fn write_nbcrow(
  w : Writer,
  cols : ArrayView[Column],
  values : ArrayView[WireValue],
) -> Unit raise TdsError {
  if cols.length() != values.length() {
    raise Malformed(
      "row has \{values.length()} values for \{cols.length()} columns",
    )
  }
  w.u8(0xD2)
  let n = (cols.length() + 7) / 8
  for b in 0..<n {
    let mut byte = 0
    for bit in 0..<8 {
      let i = b * 8 + bit
      if i < values.length() && values[i] is Null {
        byte = byte | (1 << bit)
      }
    }
    w.u8(byte)
  }
  for i in 0..<cols.length() {
    if !(values[i] is Null) {
      write_value(w, cols[i].type_info, values[i])
    }
  }
}

///|
/// Bytes a NULL takes in ROW encoding for this type.
fn null_size(ti : TypeInfo) -> Int {
  if ti.is_plp() {
    return 8
  }
  match ti {
    BigVarChar(_, _)
    | BigChar(_, _)
    | NVarChar(_, _)
    | NChar(_, _)
    | BigVarBinary(_)
    | BigBinary(_) => 2
    Variant(_) => 4
    // NTEXT: a zero text pointer length
    _ => 1
  }
}

///|
/// True when NBCROW encodes this row in fewer bytes than ROW.
pub fn nbcrow_is_smaller(
  cols : ArrayView[Column],
  values : ArrayView[WireValue],
) -> Bool {
  let mut saved = 0
  for i in 0..<values.length() {
    if values[i] is Null {
      saved += null_size(cols[i].type_info)
    }
  }
  saved > (cols.length() + 7) / 8
}
