// Exact decimal arithmetic on a big-integer coefficient plus a scale.
//
// `Decimal` itself has no precision: precision belongs to the declared
// `SqlType` and is checked with `fits`. Intermediates may grow past 38
// digits (division scales the dividend up to ~115 digits); only results are
// checked against their declared precision.

///|
/// value = coef / 10^scale
pub struct Decimal {
  coef : @bigint.BigInt
  scale : Int
} derive(Eq, Debug)

///|
/// Rounding modes SQL Server uses for decimal conversions.
pub(all) enum Rounding {
  /// decimal → smaller scale, multiplication results, money
  HalfAwayFromZero
  /// decimal → integer, division results
  TowardZero
} derive(Debug, Eq)

///|
let pow10_cache : Array[@bigint.BigInt] = {
  let a = [@bigint.BigInt::from_int(1)]
  let ten = @bigint.BigInt::from_int(10)
  for i in 1..<160 {
    a.push(a[i - 1] * ten)
  }
  a
}

///|
/// 10^n as a big integer (n >= 0).
pub fn pow10(n : Int) -> @bigint.BigInt {
  if n < pow10_cache.length() {
    pow10_cache[n]
  } else {
    @bigint.BigInt::from_int(10).pow(@bigint.BigInt::from_int(n))
  }
}

///|
fn big_abs(x : @bigint.BigInt) -> @bigint.BigInt {
  if x.compare_int(0) < 0 {
    -x
  } else {
    x
  }
}

///|
fn big_sign(x : @bigint.BigInt) -> Int {
  x.compare_int(0)
}

///|
/// Divide magnitudes with rounding; signs handled by the caller.
fn div_round_mag(
  n : @bigint.BigInt,
  d : @bigint.BigInt,
  rounding : Rounding,
) -> @bigint.BigInt {
  let q = n / d
  match rounding {
    TowardZero => q
    HalfAwayFromZero => {
      let r = n - q * d
      if (r + r).compare(d) >= 0 {
        q + @bigint.BigInt::from_int(1)
      } else {
        q
      }
    }
  }
}

///|
/// Signed division with rounding.
fn div_round(
  n : @bigint.BigInt,
  d : @bigint.BigInt,
  rounding : Rounding,
) -> @bigint.BigInt {
  let negative = big_sign(n) * big_sign(d) < 0
  let q = div_round_mag(big_abs(n), big_abs(d), rounding)
  if negative {
    -q
  } else {
    q
  }
}

///|
pub fn Decimal::new(coef : @bigint.BigInt, scale : Int) -> Decimal {
  { coef, scale, }
}

///|
pub fn Decimal::from_int64(n : Int64, scale? : Int = 0) -> Decimal {
  { coef: @bigint.BigInt::from_int64(n) * pow10(scale), scale, }
}

///|
pub fn Decimal::zero() -> Decimal {
  { coef: @bigint.BigInt::from_int(0), scale: 0, }
}

///|
pub fn Decimal::coef(self : Decimal) -> @bigint.BigInt {
  self.coef
}

///|
pub fn Decimal::scale(self : Decimal) -> Int {
  self.scale
}

///|
pub fn Decimal::is_zero(self : Decimal) -> Bool {
  self.coef.is_zero()
}

///|
/// -1, 0 or 1.
pub fn Decimal::sign(self : Decimal) -> Int {
  big_sign(self.coef)
}

///|
pub fn Decimal::neg(self : Decimal) -> Decimal {
  { coef: -self.coef, scale: self.scale, }
}

///|
/// Number of decimal digits in |coef| (0 has 0 digits).
pub fn Decimal::digits(self : Decimal) -> Int {
  if self.coef.is_zero() {
    0
  } else {
    big_abs(self.coef).to_string().length()
  }
}

///|
/// Change the scale; increasing is exact, decreasing rounds.
pub fn Decimal::rescale(
  self : Decimal,
  scale : Int,
  rounding? : Rounding = HalfAwayFromZero,
) -> Decimal {
  if scale == self.scale {
    self
  } else if scale > self.scale {
    { coef: self.coef * pow10(scale - self.scale), scale, }
  } else {
    { coef: div_round(self.coef, pow10(self.scale - scale), rounding), scale, }
  }
}

///|
/// Does the value (at its current scale) fit `decimal(precision, scale)`
/// once rescaled to `scale` with the given rounding?
pub fn Decimal::fits(
  self : Decimal,
  precision : Int,
  scale : Int,
  rounding? : Rounding = HalfAwayFromZero,
) -> Bool {
  self.rescale(scale, rounding~).digits() <= precision
}

///|
/// Integer part, truncated toward zero.
pub fn Decimal::trunc_to_bigint(self : Decimal) -> @bigint.BigInt {
  self.rescale(0, rounding=TowardZero).coef
}

///|
/// Exact comparison regardless of scale.
pub fn Decimal::compare(self : Decimal, other : Decimal) -> Int {
  let s = if self.scale > other.scale { self.scale } else { other.scale }
  self.rescale(s).coef.compare(other.rescale(s).coef)
}

///|
/// Exact sum (scale = max of the scales).
pub fn Decimal::add(self : Decimal, other : Decimal) -> Decimal {
  let s = if self.scale > other.scale { self.scale } else { other.scale }
  { coef: self.rescale(s).coef + other.rescale(s).coef, scale: s, }
}

///|
/// Exact difference (scale = max of the scales).
pub fn Decimal::sub(self : Decimal, other : Decimal) -> Decimal {
  self.add(other.neg())
}

///|
/// Exact product (scale = sum of the scales).
pub fn Decimal::mul(self : Decimal, other : Decimal) -> Decimal {
  { coef: self.coef * other.coef, scale: self.scale + other.scale, }
}

///|
/// Quotient at `scale`, rounded as asked (SQL Server truncates decimal
/// division toward zero: msduck reference/decimal-division.json). The divisor
/// must be non-zero.
pub fn Decimal::div(
  self : Decimal,
  other : Decimal,
  scale : Int,
  rounding? : Rounding = TowardZero,
) -> Decimal {
  // self/other = (a/10^sa) / (b/10^sb); result q/10^scale
  // q = a * 10^(scale + sb) / (b * 10^sa)
  let num = self.coef * pow10(scale + other.scale)
  let den = other.coef * pow10(self.scale)
  { coef: div_round(num, den, rounding), scale, }
}

///|
/// Remainder with the sign of the dividend (T-SQL `%`), scale = max of the
/// scales. The divisor must be non-zero.
pub fn Decimal::rem(self : Decimal, other : Decimal) -> Decimal {
  let s = if self.scale > other.scale { self.scale } else { other.scale }
  let a = self.rescale(s).coef
  let b = other.rescale(s).coef
  let am = big_abs(a)
  let bm = big_abs(b)
  let r = am - am / bm * bm
  { coef: if big_sign(a) < 0 { -r } else { r }, scale: s, }
}

///|
/// Parse plain decimal text: `[+|-]digits[.digits]`, `[+|-].digits` or
/// `[+|-]digits.`; no whitespace, no exponent. Returns None if malformed.
pub fn Decimal::parse(s : StringView) -> Decimal? {
  let n = s.length()
  let mut i = 0
  let mut negative = false
  if i < n && (s[i] == '+' || s[i] == '-') {
    negative = s[i] == '-'
    i += 1
  }
  let digits = StringBuilder()
  let mut int_digits = 0
  let mut frac_digits = 0
  let mut seen_dot = false
  while i < n {
    let c = s[i]
    if c >= '0' && c <= '9' {
      digits.write_char(c.to_int().unsafe_to_char())
      if seen_dot {
        frac_digits += 1
      } else {
        int_digits += 1
      }
    } else if c == '.' && !seen_dot {
      seen_dot = true
    } else {
      return None
    }
    i += 1
  }
  if int_digits + frac_digits == 0 {
    return None
  }
  let coef = @bigint.BigInt::from_string(digits.to_string())
  Some({ coef: if negative { -coef } else { coef }, scale: frac_digits, })
}

///|
/// SQL Server text form: all `scale` fraction digits, `0.` before a pure
/// fraction, `-` only for non-zero negatives (`-0.50`, `12.3400`, `7`).
pub fn Decimal::to_string(self : Decimal) -> String {
  let mag = big_abs(self.coef).to_string()
  let body = if self.scale == 0 {
    mag
  } else {
    let padded = if mag.length() <= self.scale {
      String::make(self.scale + 1 - mag.length(), '0') + mag
    } else {
      mag
    }
    let cut = padded.length() - self.scale
    padded[:cut].to_owned() + "." + padded[cut:].to_owned()
  }
  if big_sign(self.coef) < 0 {
    "-" + body
  } else {
    body
  }
}

///|
pub impl Show for Decimal with fn output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// The exact value of a finite double as a decimal (up to 1074 fraction
/// digits for subnormals).
pub fn Decimal::from_double_exact(d : Double) -> Decimal {
  let bits = d.reinterpret_as_uint64()
  let negative = bits >> 63 != 0
  let exp_bits = ((bits >> 52) & 0x7FFUL).to_int()
  let frac = bits & 0xFFFFFFFFFFFFFUL
  let (mantissa, exp2) = if exp_bits == 0 {
    (frac, -1074)
  } else {
    (frac | 0x10000000000000UL, exp_bits - 1075)
  }
  let m = @bigint.BigInt::from_uint64(mantissa)
  let r : Decimal = if exp2 >= 0 {
    { coef: m << exp2, scale: 0, }
  } else {
    // m / 2^k = m * 5^k / 10^k
    let k = -exp2
    {
      coef: m * @bigint.BigInt::from_int(5).pow(@bigint.BigInt::from_int(k)),
      scale: k,
    }
  }
  let r = r.normalize()
  if negative {
    r.neg()
  } else {
    r
  }
}

///|
/// Drop trailing fraction zeros (lowest scale with the same value).
pub fn Decimal::normalize(self : Decimal) -> Decimal {
  if self.coef.is_zero() {
    return { coef: self.coef, scale: 0, }
  }
  let ten = @bigint.BigInt::from_int(10)
  for c = self.coef, s = self.scale {
    if s > 0 && (c % ten).is_zero() {
      continue c / ten, s - 1
    } else {
      break { coef: c, scale: s, }
    }
  }
}

///|
/// Nearest double (via the exact decimal text and a correctly rounded
/// parser).
pub fn Decimal::to_double(self : Decimal) -> Double {
  @string.parse_double(self.to_string()) catch {
    _ => 0.0
  }
}
