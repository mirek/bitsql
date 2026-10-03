///|
/// A value ready for the wire, already converted to the column's type by the
/// engine. Temporal ticks are 100 ns units; the codec scales them to the
/// TYPE_INFO scale (the engine must already have rounded).
pub(all) enum WireValue {
  Null
  Int(Int64) // int family, bit (0/1)
  Float(Double)
  Money(Int64) // value * 10^4
  Decimal(Bool, Bytes) // negative?, little-endian unsigned magnitude
  Text(String) // char/varchar (CP1252 on the wire) and nchar/nvarchar
  Binary(Bytes)
  Guid(Bytes) // 16 bytes in wire order
  Date(Int) // days since 0001-01-01
  Time(Int64) // 100 ns ticks since midnight
  DateTime2(Int, Int64) // days, ticks
  DateTimeOffset(Int, Int64, Int) // UTC days, UTC ticks, offset minutes
  DateTime(Int, Int) // legacy: days since 1900-01-01, 1/300 s ticks
} derive(Debug, Eq)

///|
fn pow10(n : Int) -> Int64 {
  let mut v = 1L
  for _ in 0..<n {
    v = v * 10L
  }
  v
}

///|
fn time_len(scale : Int) -> Int {
  if scale <= 2 {
    3
  } else if scale <= 4 {
    4
  } else {
    5
  }
}

///|
fn write_uint_n(w : Writer, v : Int64, n : Int) -> Unit {
  for i in 0..<n {
    w.u8((v >> (8 * i)).to_int() & 0xFF)
  }
}

///|
fn write_time(w : Writer, scale : Int, ticks : Int64) -> Unit {
  write_uint_n(w, ticks / pow10(7 - scale), time_len(scale))
}

///|
fn write_plp(w : Writer, body : Bytes) -> Unit {
  w.u64le(body.length().to_int64().reinterpret_as_uint64())
  if body.length() > 0 {
    w.u32le(body.length().to_int64())
    w.bytes(body)
  }
  w.u32le(0)
}

///|
fn ucs2_bytes(s : String) -> Bytes {
  let w = Writer::new(size_hint=s.length() * 2)
  w.ucs2(s)
  w.to_bytes()
}

///|
/// Bytes of a value in ROW encoding for `ti`. Raises when the value does not
/// fit the declared type (an engine bug, never user error).
pub fn write_value(
  w : Writer,
  ti : TypeInfo,
  v : WireValue,
) -> Unit raise TdsError {
  if ti.is_plp() {
    match v {
      Null => w.u64le(0xFFFFFFFFFFFFFFFFUL)
      Text(s) =>
        write_plp(
          w,
          if ti is BigVarChar(_, _) {
            cp1252_encode(s)
          } else {
            ucs2_bytes(s)
          },
        )
      Binary(b) => write_plp(w, b)
      _ =>
        raise Malformed(
          "value \{@debug.to_string(v)} for PLP \{@debug.to_string(ti)}",
        )
    }
    return
  }
  match (ti, v) {
    (Int1, Int(i)) => w.u8(i.to_int())
    (Bit, Int(i)) => w.u8(i.to_int())
    (Int2, Int(i)) => w.u16le(i.to_int())
    (Int4, Int(i)) => w.i32le(i.to_int())
    (Int8, Int(i)) => w.i64le(i)
    (Float8, Float(d)) => w.i64le(d.reinterpret_as_int64())
    (Float4, Float(d)) => w.i32le(Float::from_double(d).reinterpret_as_int())
    (Money, Money(m)) => {
      w.i32le((m >> 32).to_int())
      w.i32le(m.to_int())
    }
    (Money4, Money(m)) => w.i32le(m.to_int())
    (DateTime, DateTime(d, t)) => {
      w.i32le(d)
      w.i32le(t)
    }
    (
      IntN(_)
      | BitN
      | FloatN(_)
      | MoneyN(_)
      | DateTimeN(_)
      | Guid
      | DecimalN(_, _)
      | NumericN(_, _)
      | Date
      | Time(_)
      | DateTime2(_)
      | DateTimeOffset(_),
      Null,
    ) => w.u8(0)
    (BitN, Int(i)) => {
      w.u8(1)
      w.u8(i.to_int())
    }
    (IntN(n), Int(i)) => {
      w.u8(n)
      write_uint_n(w, i, n)
    }
    (FloatN(8), Float(d)) => {
      w.u8(8)
      w.i64le(d.reinterpret_as_int64())
    }
    (FloatN(4), Float(d)) => {
      w.u8(4)
      w.i32le(Float::from_double(d).reinterpret_as_int())
    }
    (MoneyN(8), Money(m)) => {
      w.u8(8)
      w.i32le((m >> 32).to_int())
      w.i32le(m.to_int())
    }
    (MoneyN(4), Money(m)) => {
      w.u8(4)
      w.i32le(m.to_int())
    }
    (DateTimeN(8), DateTime(d, t)) => {
      w.u8(8)
      w.i32le(d)
      w.i32le(t)
    }
    (Guid, Guid(b)) => {
      w.u8(16)
      w.bytes(b)
    }
    (DecimalN(_, _) | NumericN(_, _), Decimal(neg, mag)) => {
      // Smallest whole 32-bit group count holding the magnitude (msduck
      // docs/decimal-wire.md, verified against SQL Server captures).
      let mut used = mag.length()
      while used > 0 && mag[used - 1] == b'\x00' {
        used -= 1
      }
      let groups = @cmp.maximum(1, (used + 3) / 4)
      if groups > 4 {
        raise Malformed("decimal magnitude too large")
      }
      w.u8(1 + groups * 4)
      w.u8(if neg { 0 } else { 1 })
      for i in 0..<(groups * 4) {
        w.u8(if i < mag.length() { mag[i].to_int() } else { 0 })
      }
    }
    (Date, Date(d)) => {
      w.u8(3)
      write_uint_n(w, d.to_int64(), 3)
    }
    (Time(s), Time(t)) => {
      w.u8(time_len(s))
      write_time(w, s, t)
    }
    (DateTime2(s), DateTime2(d, t)) => {
      w.u8(time_len(s) + 3)
      write_time(w, s, t)
      write_uint_n(w, d.to_int64(), 3)
    }
    (DateTimeOffset(s), DateTimeOffset(d, t, off)) => {
      w.u8(time_len(s) + 5)
      write_time(w, s, t)
      write_uint_n(w, d.to_int64(), 3)
      w.u16le(off & 0xFFFF)
    }
    (
      BigVarChar(_, _)
      | BigChar(_, _)
      | NVarChar(_, _)
      | NChar(_, _)
      | BigVarBinary(_)
      | BigBinary(_),
      Null,
    ) => w.u16le(0xFFFF)
    (BigVarChar(_, _) | BigChar(_, _), Text(s)) => {
      let b = cp1252_encode(s)
      w.u16le(b.length())
      w.bytes(b)
    }
    (NVarChar(_, _) | NChar(_, _), Text(s)) => {
      w.u16le(s.length() * 2)
      w.ucs2(s)
    }
    (BigVarBinary(_) | BigBinary(_), Binary(b)) => {
      w.u16le(b.length())
      w.bytes(b)
    }
    _ =>
      raise Malformed(
        "value \{@debug.to_string(v)} does not fit \{@debug.to_string(ti)}",
      )
  }
}

///|
fn read_uint_n(r : Reader, n : Int) -> Int64 raise TdsError {
  let mut v = 0L
  for i in 0..<n {
    v = v | (r.u8().to_int64() << (8 * i))
  }
  v
}

///|
fn sign_extend(v : Int64, n : Int) -> Int64 {
  let shift = 64 - 8 * n
  v << shift >> shift
}

///|
fn read_plp(r : Reader) -> Bytes? raise TdsError {
  let total = r.u64le()
  if total == 0xFFFFFFFFFFFFFFFFUL {
    return None
  }
  let out = Buffer()
  while true {
    let n = r.u32le().to_int()
    if n == 0 {
      break
    }
    out.write_bytes(r.bytes(n))
  }
  Some(out.to_bytes())
}

///|
/// Decodes one value (RPC parameter or ROW column) of type `ti`.
pub fn read_value(r : Reader, ti : TypeInfo) -> WireValue raise TdsError {
  if ti.is_plp() {
    return match read_plp(r) {
      None => Null
      Some(b) =>
        match ti {
          BigVarChar(_, _) => Text(cp1252_decode(b))
          NVarChar(_, _) => Text(Reader::new(b).ucs2(b.length() / 2))
          _ => Binary(b)
        }
    }
  }
  match ti {
    Null => Null
    Int1 => Int(r.u8().to_int64())
    Bit => Int(r.u8().to_int64())
    Int2 => Int(sign_extend(read_uint_n(r, 2), 2))
    Int4 => Int(r.i32le().to_int64())
    Int8 => Int(read_uint_n(r, 8))
    Float8 => Float(read_uint_n(r, 8).reinterpret_as_double())
    Float4 => Float(Float::reinterpret_from_int(r.i32le()).to_double())
    Money => {
      let hi = r.i32le().to_int64()
      let lo = r.u32le()
      Money((hi << 32) | lo)
    }
    Money4 => Money(r.i32le().to_int64())
    DateTime => {
      let d = r.i32le()
      DateTime(d, r.i32le())
    }
    DateTime4 => {
      let d = r.u16le()
      let m = r.u16le()
      DateTime(d, m * 60 * 300)
    }
    IntN(_) | BitN => {
      let n = r.u8()
      if n == 0 {
        Null
      } else if n == 1 {
        Int(read_uint_n(r, 1))
      } else {
        Int(sign_extend(read_uint_n(r, n), n))
      }
    }
    FloatN(_) =>
      match r.u8() {
        0 => Null
        4 => Float(Float::reinterpret_from_int(r.i32le()).to_double())
        8 => Float(read_uint_n(r, 8).reinterpret_as_double())
        n => raise Malformed("FLOATN length \{n}")
      }
    MoneyN(_) =>
      match r.u8() {
        0 => Null
        4 => Money(r.i32le().to_int64())
        8 => {
          let hi = r.i32le().to_int64()
          let lo = r.u32le()
          Money((hi << 32) | lo)
        }
        n => raise Malformed("MONEYN length \{n}")
      }
    DateTimeN(_) =>
      match r.u8() {
        0 => Null
        4 => {
          let d = r.u16le()
          let m = r.u16le()
          DateTime(d, m * 60 * 300)
        }
        8 => {
          let d = r.i32le()
          DateTime(d, r.i32le())
        }
        n => raise Malformed("DATETIMEN length \{n}")
      }
    Guid =>
      match r.u8() {
        0 => Null
        16 => Guid(r.bytes(16))
        n => raise Malformed("GUID length \{n}")
      }
    DecimalN(_, _) | NumericN(_, _) => {
      let n = r.u8()
      if n == 0 {
        Null
      } else {
        let sign = r.u8()
        Decimal(sign == 0, r.bytes(n - 1))
      }
    }
    Date =>
      match r.u8() {
        0 => Null
        _ => Date(read_uint_n(r, 3).to_int())
      }
    Time(s) => {
      let n = r.u8()
      if n == 0 {
        Null
      } else {
        Time(read_uint_n(r, n) * pow10(7 - s))
      }
    }
    DateTime2(s) => {
      let n = r.u8()
      if n == 0 {
        Null
      } else {
        let t = read_uint_n(r, n - 3) * pow10(7 - s)
        DateTime2(read_uint_n(r, 3).to_int(), t)
      }
    }
    DateTimeOffset(s) => {
      let n = r.u8()
      if n == 0 {
        Null
      } else {
        let t = read_uint_n(r, n - 5) * pow10(7 - s)
        let d = read_uint_n(r, 3).to_int()
        let off = sign_extend(read_uint_n(r, 2), 2).to_int()
        DateTimeOffset(d, t, off)
      }
    }
    BigVarChar(_, _)
    | BigChar(_, _)
    | NVarChar(_, _)
    | NChar(_, _)
    | BigVarBinary(_)
    | BigBinary(_) => {
      let n = r.u16le()
      if n == 0xFFFF {
        Null
      } else {
        let b = r.bytes(n)
        match ti {
          BigVarChar(_, _) | BigChar(_, _) => Text(cp1252_decode(b))
          NVarChar(_, _) | NChar(_, _) => Text(Reader::new(b).ucs2(n / 2))
          _ => Binary(b)
        }
      }
    }
  }
}
