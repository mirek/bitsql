// sql_variant conversions, comparison and properties (expected values
// from harness/corpus/variant captures).

///|
fn var_of(
  v : @types.Value,
  t : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  @types.cast(v, t, Variant)
}

///|
test "variant cast keeps the base type and converts out through it" {
  let v = var_of(s("abc"), vc(n=3))
  assert_true(v is Variant(String("abc"), VarChar(Some(3), _)))
  assert_eq(
    outcome(() => @types.cast(var_of(Int(1), Int), Variant, Date)),
    "529/3 Explicit conversion from data type int to date is not allowed.",
  )
  assert_eq(
    outcome(() => @types.cast(var_of(s("abc"), nvc(n=3)), Variant, Int)),
    "245/1 Conversion failed when converting the nvarchar value 'abc' to data type int.",
  )
  assert_eq(
    outcome(() => @types.cast(s("x"), vc(), Variant)),
    "529/1 Explicit conversion from data type varchar(max) to sql_variant is not allowed.",
  )
  assert_eq(
    outcome(() => @types.assign(var_of(Int(1), Int), Variant, Int)),
    "257/3 Implicit conversion from data type sql_variant to int is not allowed. Use the CONVERT function to run this query.",
  )
  assert_eq(
    outcome(() => @types.assign(s("x"), vc(), Variant)),
    "206/2 Operand type clash: varchar(max) is incompatible with sql_variant",
  )
}

///|
test "variant comparison orders families, then values" {
  let i = var_of(Int(1), Int)
  let f = var_of(Float(1.0), Float)
  let str = var_of(s("abc"), nvc(n=3))
  let upper = var_of(s("ABC"), vc(n=3))
  let dec = var_of(Decimal(@types.Decimal::from_int64(1L)), Decimal(10, 0))
  assert_eq(@types.compare(i, f), Some(-1)) // exact < approximate
  assert_eq(@types.compare(str, i), Some(-1)) // character < exact
  assert_eq(@types.compare(i, dec), Some(0))
  assert_eq(@types.compare(str, upper), Some(0)) // same collation, CI
  let cs = var_of(
    s("abc"),
    NVarChar(Some(3), @types.Collation::parse("Latin1_General_CS_AS").unwrap()),
  )
  // collation properties first: CS_AS flags sort before CI_AS flags
  assert_eq(@types.compare(cs, upper), Some(-1))
}

///|
test "SQL_VARIANT_PROPERTY values" {
  let p = (v : @types.Value, name : String) => {
    match @types.sql_variant_property(v, name) {
      Variant(x, _) => repr(x)
      Null => "NULL"
      other => repr(other)
    }
  }
  let t3 = var_of(Time(0L), Time(3))
  assert_eq(p(t3, "Precision"), "12")
  assert_eq(p(t3, "TotalBytes"), "7")
  let str = var_of(s("abc"), vc(n=3))
  assert_eq(p(str, "TotalBytes"), "11")
  assert_eq(p(str, "MaxLength"), "3")
  assert_eq(p(str, "basetype"), "'varchar'")
  assert_eq(p(str, "bogus"), "NULL")
  let big = var_of(
    Decimal(@types.Decimal::parse("12345678901234567890").unwrap()),
    Decimal(38, 0),
  )
  assert_eq(p(big, "MaxLength"), "9")
  assert_eq(p(big, "Collation"), "NULL")
}
