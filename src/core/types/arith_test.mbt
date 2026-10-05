///|
fn int_type(name : String) -> @types.SqlType {
  match name {
    "TINYINT" => TinyInt
    "SMALLINT" => SmallInt
    "INT" => Int
    _ => BigInt
  }
}

///|
fn int_operand(text : String, t : @types.SqlType) -> @types.Value {
  if text == "NULL" {
    return @types.Null
  }
  let n = @string.parse_int64(text) catch { _ => abort("bad int") }
  @types.int_value(t, n)
}

///|
fn op_of(text : String) -> @types.ArithOp {
  match text {
    "+" => Add
    "-" => Sub
    "*" => Mul
    "/" => Div
    _ => Mod
  }
}

///|
fn arith_outcome(
  op : @types.ArithOp,
  a : @types.Value,
  ta : @types.SqlType,
  b : @types.Value,
  tb : @types.SqlType,
) -> String {
  try @types.arith(op, a, ta, b, tb) catch {
    e => "\{e.number()}/\{e.state()}"
  } noraise {
    Null => "NULL"
    v => repr(v)
  }
}

///|
test "checked integer arithmetic matches the capture" {
  // msduck reference/checked-integer.json (240 cases)
  let failures = []
  for row in checked_integer_cases {
    let (lt, l, op, rt, r, expected) = row
    let ta = int_type(lt)
    let tb = int_type(rt)
    let got = arith_outcome(
      op_of(op),
      int_operand(l, ta),
      ta,
      int_operand(r, tb),
      tb,
    )
    if got != expected {
      failures.push(
        "\{lt} \{l} \{op} \{rt} \{r}: got \{got}, expected \{expected}",
      )
    }
  }
  assert_eq(failures, [])
  assert_eq(checked_integer_cases.length(), 240)
}

///|
test "integer arithmetic messages and promotion" {
  // msduck reference/integer-overflow.json
  inspect(
    outcome(() => {
      @types.arith(Add, @types.Int(2147483647), Int, @types.Int(1), Int)
    }),
    content="8115/2 Arithmetic overflow error converting expression to data type int.",
  )
  inspect(
    outcome(() => @types.arith(Div, @types.Int(1), Int, @types.Int(0), Int)),
    content="8134/1 Divide by zero error encountered.",
  )
  inspect(
    outcome(() => {
      @types.arith(Sub, @types.TinyInt(1), TinyInt, @types.TinyInt(2), TinyInt)
    }),
    content="8115/2 Arithmetic overflow error converting expression to data type tinyint.",
  )
  assert_eq(
    try! @types.arith(Add, @types.TinyInt(200), TinyInt, @types.Int(100), Int),
    @types.Int(300),
  )
  assert_eq(
    try! @types.arith(Add, @types.Bit(true), Bit, @types.SmallInt(1), SmallInt),
    @types.SmallInt(2),
  )
  inspect(
    outcome(() => {
      @types.arith(Add, @types.Bit(true), Bit, @types.Bit(true), Bit)
    }),
    content="8117/1 Operand data type bit is invalid for add operator.",
  )
  // character operand converts to the numeric type
  assert_eq(
    try! @types.arith(Add, s(" 41 "), vc(), @types.Int(1), Int),
    @types.Int(42),
  )
  inspect(
    outcome(() => @types.arith(Mul, @types.Int(2), Int, s("x"), vc())),
    content="245/1 Conversion failed when converting the varchar value 'x' to data type int.",
  )
  inspect(
    outcome(() => @types.negate(@types.Int(-2147483648), Int)),
    content="8115/2 Arithmetic overflow error converting expression to data type int.",
  )
  assert_eq(try! @types.negate(@types.BigInt(5L), BigInt), @types.BigInt(-5L))
}

///|
test "decimal division matches the capture" {
  // msduck reference/decimal-division.json
  let div = fn(
    a : String,
    ta : @types.SqlType,
    b : String,
    tb : @types.SqlType,
  ) -> String {
    let ra = try! @types.cast(s(a), vc(), ta)
    let rb = try! @types.cast(s(b), vc(), tb)
    let rt = try! @types.arith_result_type(Div, ta, tb)
    "\{rt} " + arith_outcome(Div, ra, ta, rb, tb)
  }
  assert_eq(
    div("1", Decimal(5, 2), "3", Decimal(5, 2)),
    "decimal(13,8) 0.33333333",
  )
  assert_eq(
    div("2", Decimal(5, 2), "3", Decimal(5, 2)),
    "decimal(13,8) 0.66666666",
  )
  assert_eq(
    div("-2", Decimal(5, 2), "3", Decimal(5, 2)),
    "decimal(13,8) -0.66666666",
  )
  assert_eq(
    div("2", Decimal(38, 6), "3", Decimal(38, 6)),
    "decimal(38,6) 0.666666",
  )
  assert_eq(
    div("-1", Decimal(38, 0), "6", Decimal(38, 0)),
    "decimal(38,6) -0.166666",
  )
  assert_eq(
    div("0.1", Decimal(38, 38), "0.3", Decimal(38, 38)),
    "decimal(38,6) 0.333333",
  )
  assert_eq(
    div("1", Decimal(38, 20), "3", Decimal(38, 20)),
    "decimal(38,6) 0.333333",
  )
  let max = "99999999999999999999999999999999999999"
  assert_eq(
    div(max, Decimal(38, 0), "1", Decimal(1, 0)),
    "decimal(38,6) 8115/2",
  )
  assert_eq(
    div(max, Decimal(38, 0), max, Decimal(38, 0)),
    "decimal(38,6) 1.000000",
  )
  assert_eq(div("1", Decimal(5, 2), "0", Decimal(5, 2)), "decimal(13,8) 8134/1")
  assert_eq(div("0", Decimal(5, 2), "0", Decimal(5, 2)), "decimal(13,8) 8134/1")
  assert_eq(
    arith_outcome(Div, @types.Null, Decimal(5, 2), dec("0"), Decimal(5, 2)),
    "NULL",
  )
  inspect(
    outcome(() => {
      @types.arith(Div, dec(max), Decimal(38, 0), dec("1"), Decimal(1, 0))
    }),
    content="8115/2 Arithmetic overflow error converting expression to data type numeric.",
  )
}

///|
test "decimal result types match captured metadata" {
  // msduck reference/numeric-arithmetic-context.json and
  // numeric-literal-metadata.json (the binder types integer literals next to
  // a decimal as (digits, 0) of the other operand's name, e.g. 2 next to
  // a numeric → numeric(1,0); numeric beside decimal is numeric)
  let rt = fn(
    op : @types.ArithOp,
    a : @types.SqlType,
    b : @types.SqlType,
  ) -> String {
    (try! @types.arith_result_type(op, a, b)).to_string()
  }
  assert_eq(rt(Div, Numeric(10, 0), Numeric(1, 0)), "numeric(16,6)")
  assert_eq(rt(Div, Numeric(10, 0), Numeric(7, 0)), "numeric(18,8)")
  assert_eq(rt(Div, Numeric(10, 0), Numeric(10, 0)), "numeric(21,11)")
  assert_eq(rt(Div, Numeric(2, 0), Numeric(10, 0)), "numeric(13,11)")
  assert_eq(rt(Div, Numeric(1, 0), Numeric(10, 0)), "numeric(12,11)")
  assert_eq(rt(Div, Numeric(2, 1), Numeric(1, 0)), "numeric(7,6)")
  assert_eq(rt(Div, Numeric(10, 0), Numeric(2, 1)), "numeric(17,6)")
  assert_eq(rt(Div, Decimal(10, 0), Int), "decimal(21,11)")
  assert_eq(rt(Div, Numeric(10, 0), Int), "numeric(21,11)")
  assert_eq(rt(Div, Decimal(5, 2), Decimal(1, 0)), "decimal(9,6)")
  assert_eq(rt(Div, Decimal(5, 2), Numeric(1, 0)), "numeric(9,6)")
  assert_eq(rt(Div, Decimal(5, 2), Int), "decimal(16,13)")
  assert_eq(rt(Mul, Numeric(2, 1), Numeric(1, 0)), "numeric(4,1)")
  assert_eq(rt(Add, Decimal(2, 1), Decimal(1, 0)), "decimal(3,1)")
  assert_eq(rt(Add, Decimal(5, 0), Numeric(5, 0)), "numeric(6,0)")
  assert_eq(rt(Div, Numeric(16, 6), Numeric(1, 0)), "numeric(18,8)")
  // documented reduction rules
  assert_eq(rt(Mul, Decimal(38, 10), Decimal(38, 10)), "decimal(38,6)")
  assert_eq(rt(Mul, Decimal(20, 10), Decimal(20, 10)), "decimal(38,17)")
  assert_eq(rt(Add, Decimal(38, 10), Decimal(38, 10)), "decimal(38,10)")
  assert_eq(rt(Mod, Decimal(10, 2), Decimal(5, 3)), "decimal(5,3)")
  assert_eq(rt(Add, Int, BigInt), "bigint")
  assert_eq(rt(Add, Money, Int), "money")
  assert_eq(rt(Add, Money, Decimal(5, 2)), "decimal(20,4)")
  assert_eq(rt(Add, Real, Int), "real")
  assert_eq(rt(Add, Real, Float), "float")
  assert_eq(rt(Add, vc(n=5), nvc(n=10)), "nvarchar(15)")
  assert_eq(rt(Add, vc(n=5000), vc(n=5000)), "varchar(8000)")
  assert_eq(rt(Add, vc(), vc(n=1)), "varchar(max)")
  assert_eq(rt(Add, Int, vc(n=5)), "int")
  let err = fn(
    op : @types.ArithOp,
    a : @types.SqlType,
    b : @types.SqlType,
  ) -> String {
    try @types.arith_result_type(op, a, b) catch {
      e => "\{e.number()}/\{e.state()} \{e.message()}"
    } noraise {
      t => t.to_string()
    }
  }
  inspect(
    err(Add, DateTime2(7), Int),
    content="206/2 Operand type clash: datetime2 is incompatible with int",
  )
  inspect(
    err(Sub, Date, Date),
    content="8117/1 Operand data type date is invalid for subtract operator.",
  )
  inspect(
    err(Add, UniqueIdentifier, UniqueIdentifier),
    content="8117/1 Operand data type uniqueidentifier is invalid for add operator.",
  )
  inspect(
    err(Mod, Float, Int),
    content="402/1 The data types float and int are incompatible in the modulo operator.",
  )
  inspect(
    err(Sub, vc(), vc()),
    content="8117/1 Operand data type varchar(max) is invalid for subtract operator.",
  )
  // captured: conversion/datetime-arithmetic
  inspect(err(Add, DateTime, Int), content="datetime")
  inspect(err(Sub, SmallDateTime, Decimal(5, 2)), content="smalldatetime")
  inspect(err(Add, SmallDateTime, DateTime), content="datetime")
  inspect(
    err(Div, DateTime, Int),
    content="257/3 Implicit conversion from data type datetime to int is not allowed. Use the CONVERT function to run this query.",
  )
  inspect(
    err(Add, DateTime, Date),
    content="402/1 The data types datetime and date are incompatible in the add operator.",
  )
}

///|
test "decimal, money and float arithmetic" {
  let d = fn(
    op : @types.ArithOp,
    a : String,
    ta : @types.SqlType,
    b : String,
    tb : @types.SqlType,
  ) -> String {
    arith_outcome(op, dec(a), ta, dec(b), tb)
  }
  assert_eq(d(Add, "1.5", Decimal(2, 1), "2.25", Decimal(3, 2)), "3.75")
  assert_eq(d(Mul, "1.5", Decimal(2, 1), "-2.25", Decimal(3, 2)), "-3.375")
  assert_eq(d(Mod, "7.5", Decimal(2, 1), "2", Decimal(1, 0)), "1.5")
  assert_eq(d(Mod, "-7.5", Decimal(2, 1), "2", Decimal(1, 0)), "-1.5")
  assert_eq(d(Sub, "99.9", Decimal(3, 1), "-0.1", Decimal(1, 1)), "100.0")
  // decimal(38,37) * decimal(38,37): p 77, s 74, integral 3 < 32 →
  // decimal(38,35); the exact product is rounded to 35 places
  let third = "0.3333333333333333333333333333333333333"
  assert_eq(
    d(Mul, third, Decimal(38, 37), third, Decimal(38, 37)),
    "0." + String::make(35, '1'),
  )
  let two_thirds = "0.6666666666666666666666666666666666667"
  assert_eq(
    d(Mul, two_thirds, Decimal(38, 37), two_thirds, Decimal(38, 37)),
    "0." + String::make(35, '4'),
  )
  // money
  let m = fn(op : @types.ArithOp, a : Int64, b : Int64) -> String {
    arith_outcome(op, @types.Money(a), Money, @types.Money(b), Money)
  }
  assert_eq(m(Add, 15000L, 25000L), "4.00")
  assert_eq(m(Mul, 15000L, 25000L), "3.75")
  assert_eq(m(Div, 10000L, 30000L), "0.33")
  inspect(
    outcome(() => {
      @types.arith(
        Add,
        @types.Money(9223372036854775807L),
        Money,
        @types.Int(1),
        Int,
      )
    }),
    content="8115/2 Arithmetic overflow error converting expression to data type money.",
  )
  // float
  assert_eq(
    arith_outcome(Div, @types.Float(1.0), Float, @types.Int(4), Int),
    "0.25",
  )
  inspect(
    outcome(() => {
      @types.arith(Div, @types.Float(1.0), Float, @types.Float(0.0), Float)
    }),
    content="8134/1 Divide by zero error encountered.",
  )
  inspect(
    outcome(() => {
      @types.arith(Mul, @types.Float(1.0e308), Float, @types.Float(10.0), Float)
    }),
    content="8115/2 Arithmetic overflow error converting expression to data type float.",
  )
  // concatenation
  assert_eq(arith_outcome(Add, s("ab"), vc(n=2), s("cd"), nvc(n=2)), "'abcd'")
}
