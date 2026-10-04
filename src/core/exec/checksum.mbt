// CHECKSUM / BINARY_CHECKSUM per-value hashes (captured: msduck
// hashbytes-checksum #038-#084, harness/corpus/conversion/checksum):
//
// - typed NULL 0x7FFFFFFF; bit, tinyint, int their value; smallint
//   zero-extended (-1 is 65535); bigint and money high ^ low word;
//   smallmoney its int32 units; float high ^ low word of the IEEE bits
//   (0 and -0 are 0), real its 32 bits;
// - date: days since 1900-01-01; time: high ^ low word of the 100 ns
//   ticks; datetime2/datetimeoffset: time hash ^ days since 1900 (UTC for
//   datetimeoffset, the offset is ignored); datetime: days ^ 1/300 s ticks;
//   smalldatetime: days << 16 | minutes;
// - uniqueidentifier: rotl4 fold of its 16 storage bytes; binary: fold of
//   the bytes with trailing zero bytes dropped;
// - strings drop trailing spaces; BINARY_CHECKSUM folds varchar bytes as
//   signed chars and nvarchar UTF-16 units; CHECKSUM does the same under
//   BIN/BIN2 collations, and under SQL_Latin1_General_CP1_CI_AS / CS_AS
//   folds per-byte sort weights (checksum_data.mbt).
//
// - decimal/numeric: |value| as a 38-digit integer (the coefficient at
//   scale 38, divided by 10 while it has more than 38 digits; 0.01 is
//   10^36, 1 and 10 are 10^37), folded with rotl4 over its 32-bit words
//   from the lowest up to the highest nonzero one (derived from oracle
//   probes, 2026-10-04; msduck hashbytes-checksum #040/#064);
//
// - Unicode text under the version-0 Windows tables (nvarchar under
//   SQL_Latin1_General_CP1_* and Latin1_General_*, varchar under
//   Latin1_General_*): the primary sort key bytes (checksum_unicode_data.mbt;
//   case and accents do not count) as little-endian 32-bit words folded with
//   rotl3, then the remaining bytes one by one with rotl3; trailing U+0020
//   and U+3000 are dropped (oracle dump, 2026-10-04);
//
// Not modelled (None → Emulator error): other
// under Windows collations (sort-key based), other SQL collations,
// sql_variant.

///|
fn fold_units(units : Iter[Int]) -> Int {
  let mut h = 0
  for u in units {
    h = rotl4(h) ^ u
  }
  h
}

///|
fn hi_lo(n : Int64) -> Int {
  n.to_int() ^ (n >> 32).to_int()
}

///|
fn signed_char(b : Byte) -> Int {
  let c = b.to_int()
  if c >= 128 {
    c - 256
  } else {
    c
  }
}

///|
fn checksum_value(v : @types.Value, ty : @types.SqlType, binary : Bool) -> Int? {
  let days1900 = (d : Int) => d - @types.DAYS_TO_1900
  match v {
    Null => Some(0x7FFFFFFF)
    Bit(b) => Some(if b { 1 } else { 0 })
    TinyInt(n) | Int(n) => Some(n)
    SmallInt(n) => Some(n & 0xFFFF)
    BigInt(n) => Some(hi_lo(n))
    Money(u) => Some(if ty is SmallMoney { u.to_int() } else { hi_lo(u) })
    Float(d) =>
      if d == 0.0 {
        Some(0)
      } else if ty is Real {
        Some(Float::from_double(d).reinterpret_as_int())
      } else {
        Some(hi_lo(d.reinterpret_as_int64()))
      }
    Date(d) => Some(days1900(d))
    Time(t) => Some(hi_lo(t))
    DateTime2(x) =>
      Some(
        hi_lo(x % @types.TICKS_PER_DAY) ^
        days1900((x / @types.TICKS_PER_DAY).to_int()),
      )
    DateTimeOffset(utc, _) =>
      Some(
        hi_lo(utc % @types.TICKS_PER_DAY) ^
        days1900((utc / @types.TICKS_PER_DAY).to_int()),
      )
    DateTime(d, u) => Some(d ^ u)
    SmallDateTime(d, m) => Some((d << 16) | m)
    Decimal(d) => Some(decimal_checksum(d))
    Guid(b) => Some(fold_units(b.iter().map(x => x.to_int())))
    Binary(b) => {
      let mut n = b.length()
      while n > 0 && b[n - 1] == b'\x00' {
        n -= 1
      }
      Some(fold_units(b[0:n].iter().map(x => x.to_int())))
    }
    String(s0) => {
      let s = rtrim_spaces(s0)
      let plain = () => {
        if ty.is_unicode() {
          fold_units(s.iter().map(c => c.to_int()))
        } else {
          fold_units(
            @types.varchar_bytes(
              s,
              ty.collation().unwrap_or(@types.default_collation),
            )
            .iter()
            .map(signed_char),
          )
        }
      }
      if binary {
        return Some(plain())
      }
      let coll = ty.collation().unwrap_or(@types.default_collation)
      // CHECKSUM weights of UTF-8 varchar are not modelled (not supported)
      if coll.utf8() && !ty.is_unicode() && coll.kind is Linguistic {
        return None
      }
      let weighted = (table : FixedArray[Int]) => {
        fold_units(@types.cp1252_bytes(s).iter().map(b => table[b.to_int()]))
      }
      match coll.kind {
        Bin | Bin2 => Some(plain())
        Linguistic if coll.version == 0 &&
          coll.code_page == 1252 &&
          !coll.kana_sensitive &&
          !coll.width_sensitive &&
          (ty.is_unicode() || !coll.sql_collation) => unicode_checksum(s)
        Linguistic if !ty.is_unicode() &&
          coll.name == "SQL_Latin1_General_CP1_CI_AS" =>
          Some(weighted(checksum_sql_ci_as))
        Linguistic if !ty.is_unicode() &&
          coll.name == "SQL_Latin1_General_CP1_CS_AS" =>
          Some(weighted(checksum_sql_cs_as))
        _ => None
      }
    }
    _ => None
  }
}

///|
fn decimal_checksum(d : @types.Decimal) -> Int {
  let coef = d.coef()
  let c = if coef.compare_int(0) < 0 { -coef } else { coef }
  if c.is_zero() {
    return 0
  }
  let shift = @cmp.minimum(38 - d.scale(), 38 - d.digits())
  let c = if shift > 0 { c * @types.pow10(shift) } else { c }
  let words = (c.bit_length() + 31) / 32
  let mask = @bigint.BigInt::from_int64(0xFFFFFFFFL)
  let mut h = 0
  for i in 0..<words {
    h = rotl4(h) ^ c.shr(32 * i).land(mask).to_int64().to_int()
  }
  h
}

///|
fn rotl3(x : Int) -> Int {
  (x << 3) | (x.reinterpret_as_uint() >> 29).reinterpret_as_int()
}

///|
/// Primary sort key bytes of one UTF-16 unit; None when not captured.
fn unicode_key(u : Int, out : Array[Int]) -> Bool {
  // binary search the run containing u
  let mut lo = 0
  let mut hi = checksum_key_runs.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let (start, count, kind, script, w0, step) = checksum_key_runs[mid]
    if u < start {
      hi = mid - 1
    } else if u >= start + count {
      lo = mid + 1
    } else {
      if kind == 2 {
        out.push(script)
        out.push(w0 + (u - start) * step)
      }
      return true
    }
  }
  for k in checksum_key4 {
    if k.0 == u {
      for i in 0..<4 {
        out.push((k.1 >> (8 * i)).to_int() & 0xFF)
      }
      return true
    }
  }
  false
}

///|
fn unicode_checksum(s : String) -> Int? {
  let mut n = s.length()
  while n > 0 &&
        (s.code_unit_at(n - 1) == ' ' || s.code_unit_at(n - 1) == '\u{3000}') {
    n -= 1
  }
  let key : Array[Int] = []
  for i in 0..<n {
    if !unicode_key(s.code_unit_at(i).to_int(), key) {
      return None
    }
  }
  let mut h = 0
  let mut i = 0
  while i + 4 <= key.length() {
    h = rotl3(h) ^
      (key[i] | (key[i + 1] << 8) | (key[i + 2] << 16) | (key[i + 3] << 24))
    i += 4
  }
  while i < key.length() {
    h = rotl3(h) ^ key[i]
    i += 1
  }
  Some(h)
}
