// Arithmetic with SQL Server overflow and divide-by-zero semantics.
//
// Captured (msduck reference/checked-integer.json, integer-overflow.json,
// decimal-division.json): integer overflow → 8115 state 2 "Arithmetic
// overflow error converting expression to data type int." (also for
// MIN / -1 and MIN % -1); x / 0 and x % 0 → 8134 state 1 "Divide by zero
// error encountered."; NULL operands give NULL even when dividing by zero;
// integer `/` truncates toward zero and `%` takes the dividend's sign;
// decimal division truncates at the result scale; decimal overflow reports
// data type `numeric`.

///|
/// 8134 state 1 (captured).
pub fn divide_by_zero_error() -> SqlError {
  sql_error(8134, "Divide by zero error encountered.")
}

///|
/// Evaluate `a op b` where `ta`/`tb` are the operands' types. The result
/// type is `arith_result_type(op, ta, tb)`; character operands meeting a
/// number are converted to the number's type first (raising 245 etc.).
pub fn arith(
  op : ArithOp,
  a : Value,
  ta : SqlType,
  b : Value,
  tb : SqlType,
) -> Value raise SqlError {
  let rt = arith_result_type(op, ta, tb)
  if a is Null || b is Null {
    return Null
  }
  if rt is (DateTime | SmallDateTime) {
    return legacy_arith(op, a, ta, b, tb, rt)
  }
  let fa = ta.family()
  let fb = tb.family()
  // character operand meeting a non-character one: implicit conversion
  let (a, ta) = if fa == FString && fb != FString {
    (cast(a, ta, tb), tb)
  } else {
    (a, ta)
  }
  let (b, tb) = if fb == FString && fa != FString {
    (cast(b, tb, ta), ta)
  } else {
    (b, tb)
  }
  match rt.family() {
    FString =>
      match (a, b) {
        (String(x), String(y)) => {
          let joined = if rt.is_unicode() {
            x + y
          } else {
            to_code_page(x + y, rt.collation().unwrap_or(default_collation))
          }
          let cap = match rt {
            VarChar(Some(n), _)
            | NVarChar(Some(n), _)
            | Char(n, _)
            | NChar(n, _) => n
            _ => joined.length()
          }
          String(
            if joined.length() > cap {
              joined.unsafe_substring(start=0, end=cap)
            } else {
              joined
            },
          )
        }
        _ => raise internal("concatenation of non-strings")
      }
    FBinary =>
      match (a, b) {
        (Binary(x), Binary(y)) => {
          let n = x.length() + y.length()
          let cap = match rt {
            VarBinary(Some(k)) => k
            _ => n
          }
          let m = if n > cap { cap } else { n }
          Binary(
            Bytes::makei(m, fn(i) {
              if i < x.length() {
                x[i]
              } else {
                y[i - x.length()]
              }
            }),
          )
        }
        _ => raise internal("binary concatenation of non-binary values")
      }
    FInteger => int_arith(op, a, b, rt)
    FDecimal => decimal_arith(op, a, b, rt)
    FMoney => money_arith(op, a, ta, b, tb, rt)
    FFloat => float_arith(op, a, b, rt)
    _ => raise internal("arithmetic result type \{rt.to_sql()}")
  }
}

///|
fn int_arith(
  op : ArithOp,
  a : Value,
  b : Value,
  rt : SqlType,
) -> Value raise SqlError {
  let (x, y) = match (a.as_int64(), b.as_int64()) {
    (Some(x), Some(y)) => (x, y)
    _ => raise internal("integer arithmetic on non-integers")
  }
  if op is (Div | Mod) && y == 0L {
    raise divide_by_zero_error()
  }
  let (lo, hi) = int_range(rt)
  // exact in BigInt, then range-checked (covers MIN / -1 and MIN % -1,
  // which SQL Server also reports as overflow)
  let bx = @bigint.BigInt::from_int64(x)
  let by = @bigint.BigInt::from_int64(y)
  let r = match op {
    Add => bx + by
    Sub => bx - by
    Mul => bx * by
    Div => {
      // truncate toward zero (on magnitudes, independent of BigInt sign rules)
      let q = big_abs(bx) / big_abs(by)
      if (x < 0L) != (y < 0L) {
        -q
      } else {
        q
      }
    }
    Mod => {
      let r = big_abs(bx) - big_abs(bx) / big_abs(by) * big_abs(by)
      if x < 0L {
        -r
      } else {
        r
      }
    }
  }
  if op == Mod && y == -1L && x == lo {
    // captured: INT_MIN % -1 → 8115 (the division overflows)
    raise overflow_expression(rt)
  }
  if r.compare_int64(lo) < 0 || r.compare_int64(hi) > 0 {
    raise overflow_expression(rt)
  }
  int_value(rt, r.to_int64())
}

///|
fn decimal_arith(
  op : ArithOp,
  a : Value,
  b : Value,
  rt : SqlType,
) -> Value raise SqlError {
  let (p, s) = rt.precision_scale().unwrap()
  let (x, y) = match (a.as_decimal(), b.as_decimal()) {
    (Some(x), Some(y)) => (x, y)
    _ => raise internal("decimal arithmetic on non-exact values")
  }
  let r = match op {
    Add => x.add(y).rescale(s)
    Sub => x.sub(y).rescale(s)
    Mul => x.mul(y).rescale(s)
    Div => {
      if y.is_zero() {
        raise divide_by_zero_error()
      }
      x.div(y, s)
    }
    Mod => {
      if y.is_zero() {
        raise divide_by_zero_error()
      }
      x.rem(y).rescale(s)
    }
  }
  if r.digits() > p {
    raise overflow_expression(rt)
  }
  Decimal(r)
}

///|
fn money_arith(
  op : ArithOp,
  a : Value,
  ta : SqlType,
  b : Value,
  tb : SqlType,
  rt : SqlType,
) -> Value raise SqlError {
  // both operands as money units (integers/bit convert exactly)
  let units = fn(v : Value, t : SqlType) -> @bigint.BigInt raise SqlError {
    match cast(v, t, rt) {
      Money(u) => @bigint.BigInt::from_int64(u)
      _ => raise internal("money operand")
    }
  }
  let x = units(a, ta)
  let y = units(b, tb)
  let ten4 = @bigint.BigInt::from_int(10000)
  let r = match op {
    Add => x + y
    Sub => x - y
    // product and quotient rounded half away from zero to 4 places
    // (unverified: SQL Server's internal money precision)
    Mul => div_round(x * y, ten4, HalfAwayFromZero)
    Div => {
      if y.is_zero() {
        raise divide_by_zero_error()
      }
      div_round(x * ten4, y, HalfAwayFromZero)
    }
    Mod => {
      if y.is_zero() {
        raise divide_by_zero_error()
      }
      let m = big_abs(x) - big_abs(x) / big_abs(y) * big_abs(y)
      if big_sign(x) < 0 {
        -m
      } else {
        m
      }
    }
  }
  let (lo, hi) = money_limits(rt)
  if r.compare_int64(lo) < 0 || r.compare_int64(hi) > 0 {
    raise overflow_expression(rt)
  }
  Money(r.to_int64())
}

///|
fn float_arith(
  op : ArithOp,
  a : Value,
  b : Value,
  rt : SqlType,
) -> Value raise SqlError {
  let (x, y) = match (as_double(a), as_double(b)) {
    (Some(x), Some(y)) => (x, y)
    _ => raise internal("float arithmetic on non-numeric values")
  }
  let r = match op {
    Add => x + y
    Sub => x - y
    Mul => x * y
    Div => {
      if y == 0.0 {
        raise divide_by_zero_error()
      }
      x / y
    }
    Mod => raise internal("float modulo")
  }
  let r = if rt is Real { Float::from_double(r).to_double() } else { r }
  if r.is_inf() || r.is_nan() {
    raise overflow_expression(rt)
  }
  Float(r)
}

///|
/// Unary minus. Integer overflow (`-(-2147483648)`) raises 8115; negating a
/// non-zero tinyint raises 8115 for tinyint (unverified); bit and character
/// operands raise 8117 for the `minus` operator.
pub fn negate(v : Value, t : SqlType) -> Value raise SqlError {
  if v is Null {
    return Null
  }
  match v {
    Bit(_) | String(_) | Binary(_) | Guid(_) =>
      raise sql_error(
        8117,
        "Operand data type \{t.clash_name()} is invalid for minus operator.",
      )
    Decimal(d) => Decimal(d.neg())
    Float(d) => Float(-d)
    Money(u) => {
      let (lo, _) = money_limits(t)
      if u == lo {
        raise overflow_expression(t)
      }
      Money(-u)
    }
    _ =>
      match v.as_int64() {
        Some(n) => {
          let (lo, hi) = int_range(t)
          let r = -n
          if n == -9223372036854775808L || r < lo || r > hi {
            raise overflow_expression(t)
          }
          int_value(t, r)
        }
        None => raise invalid_operand_error(t, Sub)
      }
  }
}
