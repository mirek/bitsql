///|
/// Default server collation SQL_Latin1_General_CP1_CI_AS as 5 wire bytes.
pub let default_collation : Bytes = b"\x09\x04\xD0\x00\x34"

///|
/// Wire-level TYPE_INFO (MS-TDS 2.2.5.6). Lengths are in *bytes* as on the
/// wire (nvarchar(10) is `NVarChar(20, ...)`); `MAX_LEN` marks (n)varchar(max)
/// and varbinary(max), which use PLP values. Collations are the raw 5 bytes.
pub(all) enum TypeInfo {
  Int1 // 0x30 tinyint NOT NULL
  Bit // 0x32
  Int2 // 0x34
  Int4 // 0x38
  Int8 // 0x7F
  Float8 // 0x3E
  Float4 // 0x3B
  Money // 0x3C
  Money4 // 0x7A
  DateTime // 0x3D
  DateTime4 // 0x3A
  IntN(Int) // 0x26 len 1/2/4/8
  BitN // 0x68
  FloatN(Int) // 0x6D len 4/8
  MoneyN(Int) // 0x6E len 4/8
  DateTimeN(Int) // 0x6F len 4/8
  Guid // 0x24 len 16
  DecimalN(Int, Int) // 0x6A precision, scale (advertised max length 17)
  NumericN(Int, Int) // 0x6C
  Date // 0x28
  Time(Int) // 0x29 scale
  DateTime2(Int) // 0x2A scale
  DateTimeOffset(Int) // 0x2B scale
  BigVarChar(Int, Bytes) // 0xA7
  BigChar(Int, Bytes) // 0xAF
  NVarChar(Int, Bytes) // 0xE7
  NChar(Int, Bytes) // 0xEF
  BigVarBinary(Int) // 0xA5
  BigBinary(Int) // 0xAD
  Null // 0x1F (RPC parameters only)
} derive(Debug, Eq)

///|
/// Length value meaning (max) for ushort-length types.
pub const MAX_LEN : Int = 0xFFFF

///|
pub fn TypeInfo::is_plp(self : TypeInfo) -> Bool {
  match self {
    BigVarChar(n, _) | NVarChar(n, _) | BigVarBinary(n) => n == MAX_LEN
    _ => false
  }
}

///|
pub fn TypeInfo::type_byte(self : TypeInfo) -> Int {
  match self {
    Int1 => 0x30
    Bit => 0x32
    Int2 => 0x34
    Int4 => 0x38
    Int8 => 0x7F
    Float8 => 0x3E
    Float4 => 0x3B
    Money => 0x3C
    Money4 => 0x7A
    DateTime => 0x3D
    DateTime4 => 0x3A
    IntN(_) => 0x26
    BitN => 0x68
    FloatN(_) => 0x6D
    MoneyN(_) => 0x6E
    DateTimeN(_) => 0x6F
    Guid => 0x24
    DecimalN(_, _) => 0x6A
    NumericN(_, _) => 0x6C
    Date => 0x28
    Time(_) => 0x29
    DateTime2(_) => 0x2A
    DateTimeOffset(_) => 0x2B
    BigVarChar(_, _) => 0xA7
    BigChar(_, _) => 0xAF
    NVarChar(_, _) => 0xE7
    NChar(_, _) => 0xEF
    BigVarBinary(_) => 0xA5
    BigBinary(_) => 0xAD
    Null => 0x1F
  }
}

///|
pub fn write_type_info(w : Writer, ti : TypeInfo) -> Unit {
  w.u8(ti.type_byte())
  match ti {
    IntN(n) | FloatN(n) | MoneyN(n) | DateTimeN(n) => w.u8(n)
    BitN => w.u8(1)
    Guid => w.u8(16)
    DecimalN(p, s) | NumericN(p, s) => {
      w.u8(17)
      w.u8(p)
      w.u8(s)
    }
    Time(s) | DateTime2(s) | DateTimeOffset(s) => w.u8(s)
    BigVarChar(n, c) | BigChar(n, c) | NVarChar(n, c) | NChar(n, c) => {
      w.u16le(n)
      w.bytes(c)
    }
    BigVarBinary(n) | BigBinary(n) => w.u16le(n)
    _ => ()
  }
}

///|
pub fn read_type_info(r : Reader) -> TypeInfo raise TdsError {
  let ty = r.u8()
  match ty {
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
    0x1F => Null
    0x26 => IntN(r.u8())
    0x68 => {
      ignore(r.u8())
      BitN
    }
    0x6D => FloatN(r.u8())
    0x6E => MoneyN(r.u8())
    0x6F => DateTimeN(r.u8())
    0x24 => {
      ignore(r.u8())
      Guid
    }
    0x6A | 0x6C => {
      ignore(r.u8())
      let p = r.u8()
      let s = r.u8()
      if ty == 0x6A {
        DecimalN(p, s)
      } else {
        NumericN(p, s)
      }
    }
    0x28 => Date
    0x29 => Time(r.u8())
    0x2A => DateTime2(r.u8())
    0x2B => DateTimeOffset(r.u8())
    0xA7 | 0xAF | 0xE7 | 0xEF => {
      let n = r.u16le()
      let c = r.bytes(5)
      match ty {
        0xA7 => BigVarChar(n, c)
        0xAF => BigChar(n, c)
        0xE7 => NVarChar(n, c)
        _ => NChar(n, c)
      }
    }
    0xA5 => BigVarBinary(r.u16le())
    0xAD => BigBinary(r.u16le())
    _ => raise Malformed("unsupported TYPE_INFO 0x\{ty.to_string(radix=16)}")
  }
}
