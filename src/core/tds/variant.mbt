// SSVARIANT (sql_variant) values: MS-TDS 2.2.5.5.4. Layout of a non-NULL
// value: total length (u32, counting everything after it), base type byte,
// property byte count, properties, data. NULL is a zero total length.
// Byte layouts verified against SQL Server 17.0.5005 captures (raw ROW
// dumps; see the tds-protocol skill findings, 2026-10-03):
//
// - fixed types (Int4 0x38, Float8 0x3E, Money 0x3C, DateTime 0x3D, Bit,
//   Guid 0x24, Date 0x28, ...): no properties, raw data;
// - DecimalN/NumericN: precision, scale; data is the sign byte and a
//   16-byte magnitude, always (17 bytes, unlike ROW's minimal groups);
// - Time/DateTime2/DateTimeOffset: scale; data as in ROW without length;
// - BigVarBinary/BigBinary: max length (u16); raw bytes;
// - character types: collation (5 bytes) then max length (u16) in bytes;
//   raw code page / UTF-16LE bytes. (tedious 20.3.3 reads max length
//   before the collation, so it decodes varchar with a garbled code page
//   table; it does so for SQL Server too.)

///|
/// Length prefix bytes ROW encoding puts before a value of `ti`, which the
/// variant data omits.
fn variant_prefix_len(ti : TypeInfo) -> Int raise TdsError {
  match ti {
    Int1
    | Bit
    | Int2
    | Int4
    | Int8
    | Float8
    | Float4
    | Money
    | Money4
    | DateTime
    | DateTime4 => 0
    Guid | Date | Time(_) | DateTime2(_) | DateTimeOffset(_) => 1
    BigVarChar(n, _)
    | BigChar(n, _)
    | NVarChar(n, _)
    | NChar(n, _)
    | BigVarBinary(n)
    | BigBinary(n) =>
      if n == MAX_LEN {
        raise Malformed("max type inside sql_variant")
      } else {
        2
      }
    DecimalN(_, _) | NumericN(_, _) => 1
    IntN(_)
    | BitN
    | FloatN(_)
    | MoneyN(_)
    | DateTimeN(_)
    | Variant(_)
    | Null
    | Xml
    | NText(_, _)
    | TextLob(_)
    | NTextLob(_)
    | ImageLob =>
      raise Malformed("base type \{@debug.to_string(ti)} inside sql_variant")
  }
}

///|
fn write_variant(
  w : Writer,
  base : TypeInfo,
  v : WireValue,
) -> Unit raise TdsError {
  if v is Null {
    raise Malformed("NULL base value inside sql_variant")
  }
  let props = Writer::new(size_hint=8)
  match base {
    DecimalN(p, s) | NumericN(p, s) => {
      props.u8(p)
      props.u8(s)
    }
    Time(s) | DateTime2(s) | DateTimeOffset(s) => props.u8(s)
    BigVarBinary(n) | BigBinary(n) => props.u16le(n)
    BigVarChar(n, c) | BigChar(n, c) | NVarChar(n, c) | NChar(n, c) => {
      props.bytes(c)
      props.u16le(n)
    }
    _ => ()
  }
  let data = match (base, v) {
    (DecimalN(_, _) | NumericN(_, _), Decimal(neg, mag)) => {
      if mag.length() > 16 {
        raise Malformed("decimal magnitude too large")
      }
      let d = Writer::new(size_hint=17)
      d.u8(if neg { 0 } else { 1 })
      for i in 0..<16 {
        d.u8(if i < mag.length() { mag[i].to_int() } else { 0 })
      }
      d.to_bytes()
    }
    _ => {
      let skip = variant_prefix_len(base)
      let tmp = Writer::new(size_hint=32)
      write_value(tmp, base, v)
      let b = tmp.to_bytes()
      b[skip:].to_owned()
    }
  }
  let p = props.to_bytes()
  w.u32le((2 + p.length() + data.length()).to_int64())
  w.u8(base.type_byte())
  w.u8(p.length())
  w.bytes(p)
  w.bytes(data)
}

///|
fn read_variant(r : Reader) -> WireValue raise TdsError {
  let total = r.u32le().to_int()
  if total == 0 {
    return Null
  }
  if total < 2 {
    raise Malformed("sql_variant length \{total}")
  }
  let bt = r.u8()
  let np = r.u8()
  if 2 + np > total {
    raise Malformed("sql_variant property length \{np}")
  }
  let props = Reader::new(r.bytes(np))
  let data = r.bytes(total - 2 - np)
  let base : TypeInfo = match bt {
    0x30 => Int1
    0x32 => Bit
    0x34 => Int2
    0x38 => Int4
    0x7F => Int8
    0x3E => Float8
    0x3B => Float4
    0x3C => Money
    0x7A => Money4
    0x3D => DateTime
    0x3A => DateTime4
    0x24 => Guid
    0x28 => Date
    0x29 => Time(props.u8())
    0x2A => DateTime2(props.u8())
    0x2B => DateTimeOffset(props.u8())
    0x6A | 0x6C => {
      let p = props.u8()
      let s = props.u8()
      if bt == 0x6A {
        DecimalN(p, s)
      } else {
        NumericN(p, s)
      }
    }
    0xA5 => BigVarBinary(props.u16le())
    0xAD => BigBinary(props.u16le())
    0xA7 | 0xAF | 0xE7 | 0xEF => {
      let c = props.bytes(5)
      let n = props.u16le()
      match bt {
        0xA7 => BigVarChar(n, c)
        0xAF => BigChar(n, c)
        0xE7 => NVarChar(n, c)
        _ => NChar(n, c)
      }
    }
    _ =>
      raise Malformed(
        "unsupported sql_variant base type 0x\{bt.to_string(radix=16)}",
      )
  }
  // re-add the ROW length prefix and decode with the base type
  let buf = Writer::new(size_hint=data.length() + 2)
  match variant_prefix_len(base) {
    0 => ()
    1 => buf.u8(data.length())
    _ => buf.u16le(data.length())
  }
  buf.bytes(data)
  let inner = read_value(Reader::new(buf.to_bytes()), base)
  Variant(base, inner)
}
