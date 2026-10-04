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
// Not modelled (None → Emulator error): decimal/numeric (a hash of the
// normalized digits SQL Server does not document), nvarchar or varchar
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
