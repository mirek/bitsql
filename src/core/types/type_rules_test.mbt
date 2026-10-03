///|
test "data type precedence order" {
  let order : Array[@types.SqlType] = [
    DateTimeOffset(7),
    DateTime2(7),
    DateTime,
    SmallDateTime,
    Date,
    Time(7),
    Float,
    Real,
    Decimal(18, 0),
    Money,
    SmallMoney,
    BigInt,
    Int,
    SmallInt,
    TinyInt,
    Bit,
    RowVersion,
    UniqueIdentifier,
    nvc(),
    @types.NChar(1, coll),
    vc(),
    @types.Char(1, coll),
    VarBinary(None),
    Binary(1),
  ]
  for i in 1..<order.length() {
    assert_true(
      @types.precedence(order[i - 1]) > @types.precedence(order[i]),
      msg="\{order[i - 1]} > \{order[i]}",
    )
  }
}

///|
test "common type of comparisons and unions" {
  let ct = fn(a : @types.SqlType, b : @types.SqlType) -> String {
    try @types.common_type(a, b) catch {
      e => "\{e.number()}/\{e.state()} \{e.message()}"
    } noraise {
      t => t.to_string()
    }
  }
  assert_eq(ct(Int, BigInt), "bigint")
  assert_eq(ct(Int, vc(n=10)), "int")
  assert_eq(ct(vc(n=10), nvc(n=5)), "nvarchar(10)")
  assert_eq(ct(@types.Char(3, coll), @types.Char(5, coll)), "char(5)")
  assert_eq(ct(@types.Char(3, coll), vc(n=2)), "varchar(3)")
  assert_eq(ct(vc(), vc(n=2)), "varchar(max)")
  assert_eq(ct(Decimal(5, 2), Decimal(10, 0)), "decimal(12,2)")
  assert_eq(ct(Decimal(38, 0), Decimal(38, 38)), "decimal(38,0)")
  assert_eq(ct(Decimal(5, 2), Int), "decimal(12,2)")
  assert_eq(ct(Decimal(5, 2), Float), "float")
  assert_eq(ct(DateTime2(3), DateTime2(7)), "datetime2(7)")
  assert_eq(ct(Date, DateTime2(2)), "datetime2(2)")
  assert_eq(ct(DateTimeOffset(0), DateTime2(7)), "datetimeoffset(0)")
  assert_eq(ct(vc(n=36), UniqueIdentifier), "uniqueidentifier")
  assert_eq(ct(Binary(4), VarBinary(Some(8))), "varbinary(8)")
  // captured message shape: "Operand type clash: int is incompatible with date"
  inspect(
    ct(Int, Date),
    content="206/2 Operand type clash: int is incompatible with date",
  )
  inspect(
    ct(Time(7), Date),
    content="206/2 Operand type clash: time is incompatible with date",
  )
  inspect(
    ct(Int, UniqueIdentifier),
    content="206/2 Operand type clash: uniqueidentifier is incompatible with int",
  )
  assert_eq(ct(Int, DateTime), "datetime")
}

///|
test "conversion legality" {
  assert_true(@types.can_convert_implicitly(vc(), Int))
  assert_true(@types.can_convert_implicitly(Int, vc()))
  assert_false(@types.can_convert_implicitly(vc(), VarBinary(None)))
  assert_true(@types.can_convert_explicitly(vc(), VarBinary(None)))
  assert_false(@types.can_convert_explicitly(Date, Int))
  assert_true(@types.can_convert_explicitly(DateTime, Int))
  assert_false(@types.can_convert_explicitly(Date, Time(7)))
  assert_true(@types.can_convert_explicitly(Time(7), DateTime2(7)))
  inspect(
    @types.implicit_conversion_error(vc(), VarBinary(None)).message(),
    content="Implicit conversion from data type varchar(max) to varbinary(max) is not allowed. Use the CONVERT function to run this query.",
  )
}

///|
test "type names" {
  let ts : Array[@types.SqlType] = [
    Decimal(10, 2),
    Numeric(5, 0),
    nvc(),
    vc(n=30),
    @types.NChar(4, coll),
    Time(3),
    DateTimeOffset(7),
    VarBinary(Some(16)),
    RowVersion,
    Float,
    Real,
  ]
  inspect(
    ts.map(t => t.to_string()).join(" "),
    content="decimal(10,2) numeric(5,0) nvarchar(max) varchar(30) nchar(4) time(3) datetimeoffset(7) varbinary(16) timestamp float real",
  )
  assert_eq(@types.SqlType::Decimal(10, 2).message_name(), "numeric")
  assert_eq(nvc().clash_name(), "nvarchar(max)")
  assert_eq(nvc().message_name(), "nvarchar")
  assert_true(@types.SqlType::Decimal(38, 38).is_valid())
  assert_false(@types.SqlType::Decimal(39, 0).is_valid())
  assert_false(@types.SqlType::Decimal(5, 6).is_valid())
  assert_false(vc(n=8001).is_valid())
  assert_false(nvc(n=4001).is_valid())
  assert_false(@types.SqlType::Time(8).is_valid())
}

///|
test "emulator error table" {
  let seen = []
  for row in @types.emulator_error_table {
    let (n, _) = row
    assert_true(n >= 50100 && n <= 50199)
    assert_false(seen.contains(n))
    seen.push(n)
  }
  let e = @types.not_supported("CURSOR KEYSET")
  assert_eq(e.number(), 50100)
  assert_eq(e.severity(), 16)
  assert_eq(e.message(), "Emulator: CURSOR KEYSET is not supported.")
  inspect(
    e,
    content="Msg 50100, Level 16, State 1: Emulator: CURSOR KEYSET is not supported.",
  )
}

///|
test "decimal value basics" {
  let d = fn(t : String) -> @types.Decimal { @types.Decimal::parse(t).unwrap() }
  assert_eq(d("0012.3400").to_string(), "12.3400")
  assert_eq(d("-.5").to_string(), "-0.5")
  assert_eq(d("5.").to_string(), "5")
  assert_eq(@types.Decimal::parse(""), None)
  assert_eq(@types.Decimal::parse("1.2.3"), None)
  assert_eq(@types.Decimal::parse(" 1"), None)
  assert_eq(d("-0.000").to_string(), "0.000")
  assert_eq(d("2.5").rescale(0).to_string(), "3")
  assert_eq(d("-2.5").rescale(0).to_string(), "-3")
  assert_eq(d("-2.5").rescale(0, rounding=TowardZero).to_string(), "-2")
  assert_eq(d("1").div(d("3"), 5).to_string(), "0.33333")
  assert_eq(d("-1").div(d("3"), 5).to_string(), "-0.33333")
  assert_eq(d("-7").rem(d("3")).to_string(), "-1")
  assert_eq(d("7").rem(d("-3")).to_string(), "1")
  assert_eq(d("123.45").digits(), 5)
  assert_true(d("999.99").fits(5, 2))
  assert_false(d("999.995").fits(5, 2))
  assert_eq(d("1.10").compare(d("1.1")), 0)
  assert_eq(@types.Decimal::from_double_exact(0.5).to_string(), "0.5")
  assert_eq(
    @types.Decimal::from_double_exact(0.1).to_string(),
    "0.1000000000000000055511151231257827021181583404541015625",
  )
  assert_eq(@types.double_to_decimal17(0.1).to_string(), "0.10000000000000001")
  assert_eq(
    @types.double_to_decimal17(1.0e20).to_string(),
    "100000000000000000000",
  )
}

///|
test "cp1252" {
  assert_eq(@types.cp1252_encode(0x20AC), Some(0x80))
  assert_eq(@types.cp1252_encode(0x81), Some(0x81))
  assert_eq(@types.cp1252_encode(0x80), None)
  assert_eq(@types.cp1252_encode(0x100), None)
  assert_eq(@types.cp1252_decode(0x9F), 0x178)
  assert_eq(@types.cp1252_string(@types.cp1252_bytes("€ÿŸ")), "€ÿŸ")
}
