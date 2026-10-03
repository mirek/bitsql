// SSVARIANT bytes captured from SQL Server 17.0.5005 (raw ROW dumps of
// `SELECT CAST(... AS sql_variant)`, 2026-10-03; tds-protocol skill
// findings).

///|
fn variant_hex(base : @tds.TypeInfo, v : @tds.WireValue) -> String raise {
  let w = @tds.Writer::new()
  @tds.write_value(w, Variant(8009), Variant(base, v))
  @tds.hex(w.to_bytes())
}

///|
fn variant_roundtrip(base : @tds.TypeInfo, v : @tds.WireValue) -> Bool raise {
  let w = @tds.Writer::new()
  @tds.write_value(w, Variant(8009), Variant(base, v))
  let back = @tds.read_value(@tds.Reader::new(w.to_bytes()), Variant(8009))
  back == Variant(base, v)
}

///|
test "SSVARIANT TYPE_INFO and NULL" {
  let w = @tds.Writer::new()
  @tds.write_type_info(w, Variant(8009))
  assert_eq(@tds.hex(w.to_bytes()), "62 49 1f 00 00")
  let n = @tds.Writer::new()
  @tds.write_value(n, Variant(8009), Null)
  assert_eq(@tds.hex(n.to_bytes()), "00 00 00 00")
}

///|
test "SSVARIANT values captured from SQL Server" {
  let coll = @tds.default_collation
  // CAST(7 AS sql_variant)
  assert_eq(variant_hex(Int4, Int(7L)), "06 00 00 00 38 00 07 00 00 00")
  // CAST('xy' AS sql_variant): collation, then max length 2
  assert_eq(
    variant_hex(BigVarChar(2, coll), Text("xy")),
    "0b 00 00 00 a7 07 09 04 d0 00 34 02 00 78 79",
  )
  // CAST(CAST(N'ab' AS nchar(5)) AS sql_variant)
  assert_eq(
    variant_hex(NChar(10, coll), Text("ab   ")),
    "13 00 00 00 ef 07 09 04 d0 00 34 0a 00 61 00 62 00 20 00 20 00 20 00",
  )
  // CAST(CAST(1.5 AS decimal(5,2)) AS sql_variant): always 16 magnitude bytes
  assert_eq(
    variant_hex(DecimalN(5, 2), Decimal(false, b"\x96")),
    "15 00 00 00 6a 02 05 02 01 96 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
  )
  // CAST(CAST('03:04:05.12' AS time(2)) AS sql_variant)
  assert_eq(
    variant_hex(Time(2), Time(110451200000L)),
    "06 00 00 00 29 01 02 80 da 10",
  )
  // CAST(CAST(0x01 AS binary(3)) AS sql_variant)
  assert_eq(
    variant_hex(BigBinary(3), Binary(b"\x01\x00\x00")),
    "07 00 00 00 ad 02 03 00 01 00 00",
  )
  // CAST(CAST(-2 AS smallint) AS sql_variant), CAST(CAST(1.5 AS smallmoney) ...)
  assert_eq(variant_hex(Int2, Int(-2L)), "04 00 00 00 34 00 fe ff")
  assert_eq(variant_hex(Money4, Money(15000L)), "06 00 00 00 7a 00 98 3a 00 00")
  // CAST(CAST('2024-01-02' AS date) AS sql_variant)
  assert_eq(variant_hex(Date, Date(738886)), "05 00 00 00 28 00 46 46 0b")
}

///|
test "SSVARIANT decodes what it encodes" {
  let coll = @tds.default_collation
  assert_true(variant_roundtrip(Int4, Int(7L)))
  assert_true(variant_roundtrip(NVarChar(8000, coll), Text("abc")))
  // decimal magnitudes come back as the 16 bytes on the wire
  let mag = Bytes::makei(16, i => {
    match i {
      0 => b'\xd2'
      1 => b'\x0a'
      _ => b'\x00'
    }
  })
  assert_true(variant_roundtrip(DecimalN(38, 0), Decimal(true, mag)))
  assert_true(variant_roundtrip(DateTime2(7), DateTime2(738886, 110451234567L)))
  assert_true(
    variant_roundtrip(
      DateTimeOffset(2),
      DateTimeOffset(738886, 20300000000L, 90),
    ),
  )
  assert_true(variant_roundtrip(Guid, Guid(Bytes::make(16, b'\x11'))))
  assert_true(variant_roundtrip(Float8, Float(-2.5)))
}
