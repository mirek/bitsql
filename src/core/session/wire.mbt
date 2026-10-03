///|
/// TDS collation bytes: LE32(lcid | flags << 20 | version << 28) + sort id.
/// Flags: IgnoreCase 1, IgnoreAccent 2, IgnoreKana 4, IgnoreWidth 8,
/// Binary 16, Binary2 32. Captured: SQL_Latin1_General_CP1_CI_AS is
/// lcid 1033, flags 13, sortId 52.
pub fn collation_bytes(c : @types.Collation) -> Bytes {
  let mut flags = 0
  match c.kind {
    Bin => flags = 16
    Bin2 => flags = 32
    Linguistic => {
      if !c.case_sensitive {
        flags = flags | 1
      }
      if !c.accent_sensitive {
        flags = flags | 2
      }
      if !c.kana_sensitive {
        flags = flags | 4
      }
      if !c.width_sensitive {
        flags = flags | 8
      }
    }
  }
  let sort_id = if c.sql_collation {
    match (c.case_sensitive, c.accent_sensitive, c.kind) {
      (_, _, Bin | Bin2) => 40
      (false, true, _) => 52
      (true, true, _) => 51
      (false, false, _) => 54
      _ => 52
    }
  } else {
    0
  }
  let version = if c.version >= 100 {
    2
  } else if c.version >= 90 {
    1
  } else {
    0
  }
  let word = 1033 | (flags << 20) | (version << 28)
  Bytes::from_array([
    word.to_byte(),
    (word >> 8).to_byte(),
    (word >> 16).to_byte(),
    (word >> 24).to_byte(),
    sort_id.to_byte(),
  ])
}

///|
fn coll(t : @types.SqlType) -> Bytes {
  collation_bytes(t.collation().unwrap_or(@types.default_collation))
}

///|
/// Wire TYPE_INFO for a result column. Non-nullable fixed-width types use
/// the fixed TDS types; nullable ones use the N variants (captured).
pub fn type_info(t : @types.SqlType, nullable : Bool) -> @tds.TypeInfo {
  match t {
    Bit => if nullable { BitN } else { Bit }
    TinyInt => if nullable { IntN(1) } else { Int1 }
    SmallInt => if nullable { IntN(2) } else { Int2 }
    Int => if nullable { IntN(4) } else { Int4 }
    BigInt => if nullable { IntN(8) } else { Int8 }
    Float => if nullable { FloatN(8) } else { Float8 }
    Real => if nullable { FloatN(4) } else { Float4 }
    Money => if nullable { MoneyN(8) } else { Money }
    SmallMoney => if nullable { MoneyN(4) } else { Money4 }
    DateTime => if nullable { DateTimeN(8) } else { DateTime }
    SmallDateTime => if nullable { DateTimeN(4) } else { DateTime4 }
    Decimal(p, s) => DecimalN(p, s)
    Numeric(p, s) => NumericN(p, s)
    Char(n, _) => BigChar(n, coll(t))
    VarChar(n, _) => BigVarChar(n.unwrap_or(@tds.MAX_LEN), coll(t))
    NChar(n, _) => NChar(n * 2, coll(t))
    NVarChar(n, _) =>
      NVarChar(
        match n {
          Some(k) => k * 2
          None => @tds.MAX_LEN
        },
        coll(t),
      )
    Binary(n) => BigBinary(n)
    VarBinary(n) => BigVarBinary(n.unwrap_or(@tds.MAX_LEN))
    Date => Date
    Time(s) => Time(s)
    DateTime2(s) => DateTime2(s)
    DateTimeOffset(s) => DateTimeOffset(s)
    UniqueIdentifier => Guid
    RowVersion => BigBinary(8)
    // captured: COLMETADATA max length 8009
    Variant => Variant(8009)
  }
}

///|
pub fn column_flags(c : @ir.ResultColumn) -> Int {
  let base = match c.origin {
    // identity columns are not updateable: 0x10 without 0x08 (captured:
    // dml/merge-delete-insert-defaults)
    // rowversion columns are not updateable either (captured: msduck
    // gaps-rowversion_identity flags 0)
    BaseColumn(identity~) =>
      if identity {
        0x10
      } else if c.ty is RowVersion {
        0
      } else {
        0x08
      }
    Computed | TableComputed => 0x20
    SetOperation | Aggregate => 0
  }
  let case_sensitive = match c.ty.collation() {
    Some(coll) => coll.case_sensitive || coll.kind is (Bin | Bin2)
    None => false
  }
  // fCaseSen (0x02) is set for case-sensitive and binary collations
  // (captured: msduck collation-wire flags 34/35).
  base | (if c.nullable { 1 } else { 0 }) | (if case_sensitive { 2 } else { 0 })
}

///|
pub fn tds_column(c : @ir.ResultColumn) -> @tds.Column {
  {
    name: c.name,
    type_info: type_info(c.ty, c.nullable),
    flags: column_flags(c),
    user_type: if c.ty is RowVersion {
      80
    } else {
      0
    },
  }
}

///|
fn decimal_wire(d : @types.Decimal) -> @tds.WireValue {
  let coef = d.coef()
  let neg = coef.compare_int(0) < 0
  let mag = if neg { coef.neg() } else { coef }
  if mag.is_zero() {
    return Decimal(false, b"\x00")
  }
  let be = mag.to_octets()
  let n = be.length()
  Decimal(neg, Bytes::makei(n, i => be[n - 1 - i]))
}

///|
pub fn wire_value(v : @types.Value) -> @tds.WireValue {
  match v {
    Null => Null
    Bit(b) => Int(if b { 1 } else { 0 })
    TinyInt(i) | SmallInt(i) | Int(i) => Int(i.to_int64())
    BigInt(i) => Int(i)
    Decimal(d) => decimal_wire(d)
    Money(m) => Money(m)
    Float(d) => Float(d)
    String(s) => Text(s)
    Binary(b) => Binary(b)
    Date(d) => Date(d)
    Time(t) => Time(t)
    DateTime2(t) =>
      DateTime2((t / @types.TICKS_PER_DAY).to_int(), t % @types.TICKS_PER_DAY)
    DateTimeOffset(t, off) =>
      DateTimeOffset(
        (t / @types.TICKS_PER_DAY).to_int(),
        t % @types.TICKS_PER_DAY,
        off,
      )
    DateTime(d, u) => DateTime(d, u)
    SmallDateTime(d, m) => DateTime(d, m * 60 * 300)
    Guid(b) => Guid(b)
    // base type in its non-nullable TYPE_INFO form (Int4, not IntN)
    Variant(inner, base) => Variant(type_info(base, false), wire_value(inner))
  }
}

///|
/// Declared SQL type of an RPC parameter from its TYPE_INFO.
pub fn param_type(ti : @tds.TypeInfo) -> @types.SqlType {
  let c = @types.default_collation
  match ti {
    Int1 | IntN(1) => TinyInt
    Int2 | IntN(2) => SmallInt
    Int4 | IntN(4) | Null => Int
    Int8 | IntN(_) => BigInt
    Bit | BitN => Bit
    Float8 | FloatN(8) => Float
    Float4 | FloatN(_) => Real
    Money | MoneyN(8) => Money
    Money4 | MoneyN(_) => SmallMoney
    DateTime | DateTimeN(8) => DateTime
    DateTime4 | DateTimeN(_) => SmallDateTime
    Guid => UniqueIdentifier
    DecimalN(p, s) => Decimal(p, s)
    NumericN(p, s) => Numeric(p, s)
    Date => Date
    Time(s) => Time(s)
    DateTime2(s) => DateTime2(s)
    DateTimeOffset(s) => DateTimeOffset(s)
    BigVarChar(n, _) =>
      VarChar(if n == @tds.MAX_LEN { None } else { Some(n) }, c)
    BigChar(n, _) => Char(n, c)
    NVarChar(n, _) =>
      NVarChar(if n == @tds.MAX_LEN { None } else { Some(n / 2) }, c)
    NChar(n, _) => NChar(n / 2, c)
    BigVarBinary(n) => VarBinary(if n == @tds.MAX_LEN { None } else { Some(n) })
    BigBinary(n) => Binary(n)
    Variant(_) => Variant
  }
}

///|
pub fn param_value(ty : @types.SqlType, w : @tds.WireValue) -> @types.Value {
  match (ty, w) {
    (_, Null) => Null
    (Bit, Int(i)) => Bit(i != 0L)
    (TinyInt, Int(i)) => TinyInt(i.to_int())
    (SmallInt, Int(i)) => SmallInt(i.to_int())
    (Int, Int(i)) => Int(i.to_int())
    (BigInt, Int(i)) => BigInt(i)
    (Float | Real, Float(d)) => Float(d)
    (Money | SmallMoney, Money(m)) => Money(m)
    (Decimal(_, s) | Numeric(_, s), Decimal(neg, mag)) => {
      let n = mag.length()
      let be = Bytes::makei(n, i => mag[n - 1 - i])
      let coef = @bigint.BigInt::from_octets(be)
      Decimal(@types.Decimal::new(if neg { coef.neg() } else { coef }, s))
    }
    (_, Text(s)) => String(s)
    (_, Binary(b)) => Binary(b)
    (_, Guid(b)) => Guid(b)
    (_, Date(d)) => Date(d)
    (_, Time(t)) => Time(t)
    (_, DateTime2(d, t)) => DateTime2(d.to_int64() * @types.TICKS_PER_DAY + t)
    (_, DateTimeOffset(d, t, off)) =>
      DateTimeOffset(d.to_int64() * @types.TICKS_PER_DAY + t, off)
    (SmallDateTime, DateTime(d, u)) => SmallDateTime(d, u / 18000)
    (_, DateTime(d, u)) => DateTime(d, u)
    (_, Int(i)) => BigInt(i)
    (_, Float(d)) => Float(d)
    (_, Money(m)) => Money(m)
    (_, Decimal(_, _)) => Null
    // base collation is checked by `check_variant_params` (rpc.mbt)
    (_, Variant(base, inner)) => {
      let t = param_type(base)
      Variant(param_value(t, inner), t)
    }
  }
}

///|
/// sql_variant RPC parameters (tedious cannot send them; other clients can)
/// carry their base type's collation, which bitsql does not map back from
/// TDS bytes: only the default collation is accepted.
fn check_variant_params(params : Array[@tds.RpcParam]) -> Unit raise {
  for p in params {
    match p.value {
      Variant(
        BigVarChar(_, c)
        | BigChar(_, c)
        | NVarChar(_, c)
        | NChar(_, c),
        _
      ) if c != @tds.default_collation =>
        raise @types.not_supported(
          "a sql_variant parameter with a non-default collation",
        )
      _ => ()
    }
  }
}
