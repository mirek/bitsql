// Math built-ins (bound in bind/fn_math.mbt). Arguments arrive converted
// to the computation type (decimals keep their own precision).

///|
fn invalid_float_op() -> @types.SqlError {
  @types.sql_error(3623, "An invalid floating point operation occurred.")
}

///|
fn float_overflow() -> @types.SqlError {
  @types.overflow_expression(Float)
}

///|
fn numeric_overflow() -> @types.SqlError {
  // captured: decimal results report "numeric" even for DECIMAL types
  @types.sql_error(
    8115,
    "Arithmetic overflow error converting expression to data type numeric.",
    state=2,
  )
}

///|
/// A float result: NaN is 3623, infinity an overflow.
fn checked_float(d : Double) -> @types.Value raise @types.SqlError {
  if d.is_nan() {
    raise invalid_float_op()
  }
  if d.is_inf() {
    raise float_overflow()
  }
  Float(d)
}

///|
fn as_double(v : @types.Value) -> Double? {
  match v {
    Float(d) => Some(d)
    _ =>
      match v.as_decimal() {
        Some(x) => Some(x.to_double())
        None => None
      }
  }
}

///|
/// Converts a float result to the function's result type (integers
/// truncate, decimals and money round, overflow messages as for CAST).
fn from_double(
  d : Double,
  t : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  if d.is_nan() {
    raise invalid_float_op()
  }
  match t {
    Float | Real => checked_float(d)
    _ => {
      if d.is_inf() {
        raise float_overflow()
      }
      @types.cast(Float(d), Float, t)
    }
  }
}

///|
fn ten_pow(n : Int) -> @bigint.BigInt {
  @types.pow10(n)
}

///|
/// Rounds (or truncates) an exact decimal at `n` decimal places, n may be
/// negative; the scale is kept.
fn round_decimal(
  d : @types.Decimal,
  n : Int64,
  truncate : Bool,
) -> @types.Decimal {
  let s = d.scale()
  if n >= s.to_int64() {
    return d
  }
  let drop = (s.to_int64() - n).to_int()
  if drop > 80 {
    return @types.Decimal::new(@bigint.BigInt::from_int(0), s)
  }
  let unit = ten_pow(drop)
  let c = d.coef()
  let q = c / unit
  let r = c % unit
  let zero = @bigint.BigInt::from_int(0)
  let one = @bigint.BigInt::from_int(1)
  let q = if !truncate &&
    (if r < zero { zero - r } else { r }) * @bigint.BigInt::from_int(2) >= unit {
    if c < zero {
      q - one
    } else {
      q + one
    }
  } else {
    q
  }
  @types.Decimal::new(q * unit, s)
}

///|
fn int_overflow(t : @types.SqlType) -> @types.SqlError {
  @types.overflow_expression(t)
}

///|
fn round_value(
  x : @types.Value,
  n : Int64,
  truncate : Bool,
  t : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  match x {
    Int(_) | BigInt(_) => {
      let i = x.as_int64().unwrap_or(0L)
      if n >= 0L {
        return x
      }
      let r = round_decimal(@types.Decimal::from_int64(i), n, truncate)
      let (lo, hi) = @types.int_range(t)
      let c = r.coef()
      if c < @bigint.BigInt::from_int64(lo) ||
        c > @bigint.BigInt::from_int64(hi) {
        raise int_overflow(t)
      }
      @types.int_value(t, c.to_int64())
    }
    Decimal(d) => {
      let r = round_decimal(d, n, truncate)
      let (p, s) = t.precision_scale().unwrap_or((38, d.scale()))
      let r = r.rescale(s)
      if !r.fits(p, s) {
        raise numeric_overflow()
      }
      Decimal(r)
    }
    Money(m) => {
      let r = round_decimal(
        @types.Decimal::new(@bigint.BigInt::from_int64(m), 4),
        n,
        truncate,
      )
      Money(r.coef().to_int64())
    }
    Float(f) => {
      if f.is_nan() || f.is_inf() {
        return x
      }
      let r = round_decimal(@types.Decimal::from_double_exact(f), n, truncate)
      Float(r.to_double())
    }
    _ => raise @types.not_supported("ROUND of \{t.to_sql()}")
  }
}

///|
/// SQL Server's RAND: L'Ecuyer's combined generator with the classic
/// 12345/67890 state; RAND(seed) sets s1 = |seed| (0 → 12345), s2 = 67890
/// (reverse-engineered from captures: RAND(7) then RAND(), RAND()
/// reproduce exactly).
fn rand_next(rt : Runtime) -> Double {
  let m1 = 2147483563L
  let m2 = 2147483399L
  if rt.rand_s1 == 0L {
    rt.rand_s1 = (rt.next_random() % (m1 - 1L).reinterpret_as_uint64()).reinterpret_as_int64() +
      1L
    rt.rand_s2 = (rt.next_random() % (m2 - 1L).reinterpret_as_uint64()).reinterpret_as_int64() +
      1L
  }
  rt.rand_s1 = 40014L * rt.rand_s1 % m1
  rt.rand_s2 = 40692L * rt.rand_s2 % m2
  let mut z = rt.rand_s1 - rt.rand_s2
  if z < 1L {
    z += m1 - 1L
  }
  z.to_double() * 4.656613e-10
}

///|
fn rand_seed(rt : Runtime, seed : Int64) -> Unit {
  let s = seed.abs()
  rt.rand_s1 = if s == 0L || s >= 2147483563L { 12345L } else { s }
  rt.rand_s2 = 67890L
}

///|
fn call_math(
  ctx : Ctx,
  name : String,
  v : Array[@types.Value],
  _args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value? raise @types.SqlError {
  if name == "PI" {
    return Some(Float(@math.PI))
  }
  if name == "RAND" {
    if v.length() == 1 {
      match int_of(v[0]) {
        Some(seed) => rand_seed(ctx.rt, seed)
        None => return Some(Null)
      }
    }
    return Some(Float(rand_next(ctx.rt)))
  }
  if !(name
    is ("ABS"
    | "SIGN"
    | "CEILING"
    | "FLOOR"
    | "ROUND"
    | "POWER"
    | "SQUARE"
    | "SQRT"
    | "EXP"
    | "LOG"
    | "LOG10"
    | "SIN"
    | "COS"
    | "TAN"
    | "COT"
    | "ASIN"
    | "ACOS"
    | "ATAN"
    | "ATN2"
    | "DEGREES"
    | "RADIANS")) {
    return None
  }
  if v.iter().any(x => x is Null) {
    // ROUND's third argument may be NULL (captured: ROUND(1.55, 1, NULL))
    if !(name == "ROUND" &&
      v.length() == 3 &&
      !(v[0] is Null) &&
      !(v[1] is Null)) {
      return Some(Null)
    }
  }
  let t = e.ty
  let x = v[0]
  let f = (op : (Double) -> Double) => {
    match as_double(x) {
      Some(d) => checked_float(op(d))
      None => Null
    }
  }
  let r : @types.Value = match name {
    "ABS" =>
      match x {
        Int(i) =>
          if i == -2147483648 {
            raise int_overflow(Int)
          } else {
            Int(i.abs())
          }
        BigInt(i) =>
          if i == -9223372036854775807L - 1L {
            raise int_overflow(BigInt)
          } else {
            BigInt(i.abs())
          }
        Float(d) => Float(d.abs())
        Decimal(d) => Decimal(if d.sign() < 0 { d.neg() } else { d })
        Money(m) => Money(m.abs())
        _ => raise @types.not_supported("ABS of \{t.to_sql()}")
      }
    "SIGN" =>
      match x {
        Int(i) => Int(if i > 0 { 1 } else if i < 0 { -1 } else { 0 })
        BigInt(i) => BigInt(if i > 0L { 1L } else if i < 0L { -1L } else { 0L })
        Float(d) =>
          Float(if d > 0.0 { 1.0 } else if d < 0.0 { -1.0 } else { 0.0 })
        Decimal(d) =>
          Decimal(
            @types.Decimal::from_int64(d.sign().to_int64()).rescale(d.scale()),
          )
        Money(m) =>
          Money(if m > 0L { 10000L } else if m < 0L { -10000L } else { 0L })
        _ => raise @types.not_supported("SIGN of \{t.to_sql()}")
      }
    "CEILING" | "FLOOR" => {
      let up = name == "CEILING"
      match x {
        Int(_) | BigInt(_) => x
        Float(d) => Float(if up { d.ceil() } else { d.floor() })
        Decimal(d) => {
          let tr = d.rescale(0, rounding=TowardZero)
          let exact = tr.compare(d) == 0
          let one = @types.Decimal::from_int64(1L)
          let r = if exact {
            tr
          } else if up && d.sign() > 0 {
            tr.add(one)
          } else if !up && d.sign() < 0 {
            tr.sub(one)
          } else {
            tr
          }
          Decimal(r.rescale(0))
        }
        Money(m) => {
          let q = m / 10000L
          let exact = m % 10000L == 0L
          let r = if exact {
            q
          } else if up && m > 0L {
            q + 1L
          } else if !up && m < 0L {
            q - 1L
          } else {
            q
          }
          Money(r * 10000L)
        }
        _ => raise @types.not_supported("\{name} of \{t.to_sql()}")
      }
    }
    "ROUND" => {
      let n = int_of(v[1]).unwrap_or(0L)
      let truncate = v.length() > 2 &&
        (match int_of(v[2]) {
          Some(k) => k != 0L
          None => false
        })
      round_value(x, n, truncate, t)
    }
    "POWER" => {
      guard as_double(x) is Some(b) && as_double(v[1]) is Some(y) else {
        return Some(Null)
      }
      if b == 0.0 && y < 0.0 {
        raise @types.divide_by_zero_error()
      }
      from_double(@math.pow(b, y), t)
    }
    "SQUARE" => f(d => d * d)
    "SQRT" => f(d => if d < 0.0 { @double.not_a_number } else { d.sqrt() })
    "EXP" => f(d => @math.exp(d))
    "LOG" => {
      guard as_double(x) is Some(d) else { return Some(Null) }
      if d <= 0.0 {
        raise invalid_float_op()
      }
      if v.length() > 1 {
        guard as_double(v[1]) is Some(base) else { return Some(Null) }
        if base <= 0.0 || base == 1.0 {
          raise invalid_float_op()
        }
        checked_float(@math.ln(d) / @math.ln(base))
      } else {
        checked_float(@math.ln(d))
      }
    }
    "LOG10" =>
      f(d => if d <= 0.0 { @double.not_a_number } else { @math.log10(d) })
    "SIN" => f(d => @math.sin(d))
    "COS" => f(d => @math.cos(d))
    "TAN" => f(d => @math.tan(d))
    "COT" =>
      // SQL Server's COT is COS/SIN (captured: 911 inputs agree bit for
      // bit with its own COS/SIN, 1/TAN differs in a third of them)
      f(d => {
        let s = @math.sin(d)
        if s == 0.0 {
          @double.not_a_number
        } else {
          @math.cos(d) / s
        }
      })
    "ASIN" =>
      f(d => {
        if d < -1.0 || d > 1.0 {
          @double.not_a_number
        } else {
          @math.asin(d)
        }
      })
    "ACOS" =>
      f(d => {
        if d < -1.0 || d > 1.0 {
          @double.not_a_number
        } else {
          @math.acos(d)
        }
      })
    "ATAN" => f(d => @math.atan(d))
    "ATN2" => {
      guard as_double(x) is Some(a) && as_double(v[1]) is Some(b) else {
        return Some(Null)
      }
      if a == 0.0 && b == 0.0 {
        raise invalid_float_op()
      }
      checked_float(@math.atan2(a, b))
    }
    "DEGREES" | "RADIANS" => {
      guard as_double(x) is Some(d) else { return Some(Null) }
      let r = if name == "DEGREES" {
        d * (180.0 / @math.PI)
      } else {
        d * (@math.PI / 180.0)
      }
      match t {
        Int | BigInt => {
          let tr = r.trunc()
          let (lo, hi) = @types.int_range(t)
          if tr < lo.to_double() || tr > hi.to_double() {
            raise int_overflow(t)
          }
          @types.int_value(t, tr.to_int64())
        }
        _ => from_double(r, t)
      }
    }
    _ => return None
  }
  Some(r)
}
