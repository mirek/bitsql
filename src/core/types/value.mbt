// Runtime values. A `Value` is interpreted together with the binder-computed
// `SqlType`: the type carries length/precision/scale/collation, the value
// only the data. Representations (docs/design/fidelity-traps.md):
//
// - exact numerics are integers or a big-integer `Decimal`; never floats;
// - temporal values are integer ticks (100 ns), never floats or ms clocks;
// - uniqueidentifier keeps the 16 bytes in SQL Server storage order;
// - char/varchar keep a MoonBit String whose every code unit is a code page
//   1252 character (conversion into varchar enforces this), so one code
//   unit == one byte of storage; nchar/nvarchar keep raw UTF-16, including
//   unpaired surrogates.

///|
/// A runtime SQL value.
pub(all) enum Value {
  Null
  Bit(Bool)
  /// tinyint 0..255
  TinyInt(Int)
  SmallInt(Int)
  Int(Int)
  BigInt(Int64)
  /// decimal / numeric: exact coefficient and scale
  Decimal(Decimal)
  /// money and smallmoney: integer units of 1/10000
  Money(Int64)
  /// float, and real (real values are exactly representable binary32)
  Float(Double)
  /// char / varchar / nchar / nvarchar
  String(String)
  /// binary / varbinary / rowversion (8 bytes, big-endian counter)
  Binary(Bytes)
  /// date: days since 0001-01-01
  Date(Int)
  /// time: 100 ns ticks since midnight, rounded to the declared scale
  Time(Int64)
  /// datetime2: 100 ns ticks since 0001-01-01 00:00:00
  DateTime2(Int64)
  /// datetimeoffset: UTC ticks since 0001-01-01, offset in minutes (-840..840)
  DateTimeOffset(Int64, Int)
  /// datetime: days since 1900-01-01 (may be negative), 1/300 s since midnight
  DateTime(Int, Int)
  /// smalldatetime: days since 1900-01-01, minutes since midnight
  SmallDateTime(Int, Int)
  /// uniqueidentifier: 16 bytes in SQL Server (mixed-endian) storage order
  Guid(Bytes)
} derive(Debug, Eq)

///|
pub fn Value::is_null(self : Value) -> Bool {
  self is Null
}
