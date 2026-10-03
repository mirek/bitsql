// Storage bytes of float, real, money, smallmoney and decimal/numeric, as
// CONVERT(varbinary, x) shows them, and the conversions back (captured:
// msduck concat-numeric-format *-native, harness/corpus/conversion/
// numeric-bytes):
//
// - float / real: IEEE 754 binary64 / binary32, big-endian (-1.5 real is
//   BFC00000). varbinary/binary → float/real is not allowed (529).
// - money / smallmoney: the 1/10000 units as a big-endian two's-complement
//   int64 / int32 (0.0051 is 0000000000000033).
// - decimal(p,s) / numeric(p,s): p, s, 0, sign (1 positive or zero, 0
//   negative), then the magnitude little-endian in the fewest whole 4-byte
//   groups: 12.5 as numeric(12,3) is 0C030001D4300000.
//
// Like integers, float and money bytes keep their low-order end when cut
// (CONVERT(varbinary(3), 1.5e0) is 000000) and are zero-padded on the left
// into binary(n); decimal bytes keep their head when cut (varbinary(4) of
// numeric(12,3) is 0C030001) but are padded on the left too.

///|
/// Storage bytes and whether a cut keeps the tail (true) or the head.
fn numeric_storage_bytes(v : Value, from : SqlType) -> (Bytes, Bool)? {
  match v {
    Float(d) =>
      if from is Real {
        let bits = Float::from_double(d)
          .reinterpret_as_uint()
          .reinterpret_as_int()
        Some((big_endian(bits.to_int64(), 4), true))
      } else {
        Some((big_endian(d.reinterpret_as_int64(), 8), true))
      }
    Money(u) =>
      Some((big_endian(u, if from is SmallMoney { 4 } else { 8 }), true))
    Decimal(d) => {
      let (p, s) = match from.precision_scale() {
        Some(ps) => ps
        None => return None
      }
      let r = d.rescale(s)
      let negative = r.sign() < 0
      let mag = if negative { r.coef().neg() } else { r.coef() }
      // the magnitude takes the fewest whole 4-byte groups (captured:
      // 12.5 as numeric(12,3) has 4 magnitude bytes, -1e14 as decimal(18,4)
      // 8), as in the TDS row format
      ignore(p)
      let raw = mag.to_octets()
      let used = if mag.is_zero() { 0 } else { raw.length() }
      let w = if used == 0 { 4 } else { (used + 3) / 4 * 4 }
      let be = mag.to_octets(length=w)
      if be.length() != w {
        return None
      }
      let out = Bytes::makei(4 + w, fn(i) {
        match i {
          0 => p.to_byte()
          1 => s.to_byte()
          2 => b'\x00'
          3 => if negative { b'\x00' } else { b'\x01' }
          _ => be[w - 1 - (i - 4)]
        }
      })
      Some((out, false))
    }
    _ => None
  }
}

///|
/// binary → money/smallmoney: the last 8 (4) bytes, zero-extended on the
/// left, as a big-endian signed integer of 1/10000 units (captured: 0x33
/// and 0x000000000000000033 are both 0.0051).
fn binary_to_money(b : Bytes, to : SqlType) -> Value {
  let w = if to is SmallMoney { 4 } else { 8 }
  let n = b.length()
  let mut x = 0L
  for i in 0..<w {
    let k = n - w + i
    let byte = if k >= 0 { b[k].to_int64() } else { 0L }
    x = (x << 8) | byte
  }
  if w == 4 {
    x = x.to_int().to_int64() // sign-extend the low 32 bits
  }
  Money(x)
}

///|
/// binary → decimal/numeric: the storage layout above.
fn binary_to_decimal(
  b : Bytes,
  from : SqlType,
  to : SqlType,
) -> Decimal raise SqlError {
  if b.length() < 4 {
    raise error_converting(from, to)
  }
  let p = b[0].to_int()
  let s = b[1].to_int()
  if p > 38 {
    // captured: 0x27… is 8115 state 6
    raise sql_error(
      8115,
      "Arithmetic overflow error converting \{from.base_name()} to data type \{to.message_name()}.",
      state=6,
    )
  }
  if p < 1 {
    raise not_supported(
      "conversion of binary data with precision \{p} to \{to.to_sql()}",
      number=EMU_CONVERSION_NOT_SUPPORTED,
    )
  }
  // captured: scale above precision is 8114 state 5
  if s > p {
    raise error_converting(from, to)
  }
  // the magnitude is every byte after the header, little-endian (captured:
  // 9 bytes, 0x050201003930000000, convert to -123.45); shorter than one
  // 4-byte group is 8114 (unverified beyond 0x01)
  let w = b.length() - 4
  if w < 4 {
    raise error_converting(from, to)
  }
  let be = Bytes::makei(w, fn(i) { b[4 + w - 1 - i] })
  let mag = @bigint.BigInt::from_octets(be[:])
  let d = Decimal::new(mag, s)
  if b[3] == b'\x00' {
    d.neg()
  } else {
    d
  }
}
