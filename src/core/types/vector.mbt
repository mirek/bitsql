///|
/// Native float32 components; display text is not a lossless storage format.
/// SQL contracts: harness/corpus/sql2025/vector-{functions,contracts,json}.
pub struct VectorData {
  priv components : Array[Double]
  priv base_type : VectorBase
} derive(Debug, Eq)

///|
pub fn VectorData::dimensions(self : VectorData) -> Int {
  self.components.length()
}

///|
pub fn VectorData::to_text(self : VectorData) -> String {
  "[" + self.components.map(v => format_float_scientific(v, 8)).join(",") + "]"
}

///|
fn vector_json_error(state : Int, reason : String) -> SqlError {
  sql_error(13670, "Input JSON is not a valid Vector : '\{reason}'.", state~)
}

///|
fn JsonTypeParser::vector_reject(self : JsonTypeParser) -> Unit raise SqlError {
  match self.peek() {
    110 => {
      self.literal("null", StringBuilder())
      raise vector_json_error(4, "Null Not Supported")
    }
    116 => {
      self.literal("true", StringBuilder())
      raise vector_json_error(9, "Boolean not supported")
    }
    102 => {
      self.literal("false", StringBuilder())
      raise vector_json_error(9, "Boolean Not Supported")
    }
    34 => {
      ignore(self.string())
      raise vector_json_error(5, "String not Supported")
    }
    123 => {
      self.pos += 1
      self.ws()
      raise vector_json_error(
        if self.peek() == 125 {
          7
        } else {
          10
        },
        if self.peek() == 125 {
          "Empty object Not Suppoted"
        } else {
          "Object Not Supported"
        },
      )
    }
    91 => {
      self.pos += 1
      self.ws()
      raise vector_json_error(
        if self.peek() == 93 {
          8
        } else {
          1
        },
        if self.peek() == 93 {
          "Empty Array not Supported"
        } else {
          "Malformed JSON"
        },
      )
    }
    45 | 48..=57 => raise vector_json_error(1, "Malformed JSON")
    _ => raise self.fail_at(self.pos)
  }
}

///|
/// JSON numeric grammar, retaining the raw number until binary32 rounding.
/// The native json type's decimal canonicalization is not applicable here.
fn JsonTypeParser::vector_number(
  self : JsonTypeParser,
  base : VectorBase,
) -> Double raise SqlError {
  let start = self.pos
  let digit = () => self.peek() >= 48 && self.peek() <= 57
  if self.peek() == 45 {
    self.pos += 1
  }
  if !digit() {
    raise self.fail_at(start)
  }
  if self.peek() == 48 {
    self.pos += 1
    if digit() {
      raise self.fail_at(start)
    }
  } else {
    while digit() {
      self.pos += 1
    }
  }
  if self.peek() == 46 {
    self.pos += 1
    if !digit() {
      raise self.fail_at(start)
    }
    while digit() {
      self.pos += 1
    }
  }
  if self.peek() is (69 | 101) {
    self.pos += 1
    if self.peek() is (43 | 45) {
      self.pos += 1
    }
    if !digit() {
      raise self.fail_at(start)
    }
    while digit() {
      self.pos += 1
    }
  }
  let number = parse_float_text(utf8_text(self.b[start:self.pos])).unwrap_or(
    1.0 / 0.0,
  )
  let rounded = Float::from_double(number).to_double()
  if rounded.is_inf() || rounded.is_nan() {
    raise sql_error(
      42241,
      "Input JSON contains out-of-range values for \{base.name()}.",
    )
  }
  if base == Float16 {
    return vector_half(rounded)
  }
  if rounded == 0.0 {
    0.0
  } else {
    rounded
  }
}

///|
pub fn vector_parse(
  text : String,
  dimensions : Int,
  base? : VectorBase = Float32,
) -> VectorData raise SqlError {
  if dimensions < 1 || dimensions > (if base == Float16 { 3996 } else { 1998 }) {
    raise not_supported("invalid \{base.name()} vector descriptor")
  }
  let p : JsonTypeParser = { b: @utf8.encode(text), pos: 0, }
  p.ws()
  if p.peek() != 91 {
    p.vector_reject()
  }
  p.pos += 1
  p.ws()
  if p.peek() == 93 {
    raise vector_json_error(8, "Empty Array not Supported")
  }
  let components : Array[Double] = []
  while true {
    if !(p.peek() == 45 || (p.peek() >= 48 && p.peek() <= 57)) {
      p.vector_reject()
    }
    components.push(p.vector_number(base))
    if components.length() > 3996 {
      raise emulator_error(
        EMU_WORK_BUDGET,
        "vector JSON exceeds the component budget",
      )
    }
    p.ws()
    if p.peek() == 93 {
      p.pos += 1
      break
    }
    if p.peek() != 44 {
      raise p.fail_at(p.pos)
    }
    p.pos += 1
    p.ws()
  }
  p.ws()
  if p.pos != p.b.length() {
    raise p.fail_at(p.pos)
  }
  if components.length() != dimensions {
    raise sql_error(
      42204,
      "The vector dimensions \{dimensions} and \{components.length()} do not match.",
      state=4,
    )
  }
  { components, base_type: base, }
}

///|
pub fn VectorData::norm(
  self : VectorData,
  kind : String,
) -> Double raise SqlError {
  if self.base_type == Float16 {
    raise vector_half_norm_error("vector_norm")
  }
  let option = kind.to_lower()
  if !(option is ("norm1" | "norm2" | "norminf")) {
    raise sql_error(
      42210,
      "The requested norm function '\{kind}' is not supported by vector_norm/vector_normalize. Please provide a valid norm function.",
    )
  }
  // SQL Server's eight-lane path rounds products and accumulators to
  // binary32, then reduces to binary64. A tail shorter than eight uses
  // binary64 arithmetic (vector-norms and vector-norm-extremes captures).
  let lanes = Array::make(8, 0.0)
  let full = self.components.length() / 8 * 8
  for i in 0..<full {
    let value = self.components[i]
    let positive = if value < 0.0 { -value } else { value }
    let lane = i % 8
    lanes[lane] = match option {
      "norm1" => Float::from_double(lanes[lane] + positive).to_double()
      "norm2" =>
        Float::from_double(
          lanes[lane] + Float::from_double(value * value).to_double(),
        ).to_double()
      _ => if positive > lanes[lane] { positive } else { lanes[lane] }
    }
  }
  let mut sum = 0.0
  for value in lanes {
    if option == "norminf" {
      if value > sum {
        sum = value
      }
    } else {
      sum += value
    }
  }
  for i in full..<self.components.length() {
    let value = self.components[i]
    let positive = if value < 0.0 { -value } else { value }
    match option {
      "norm1" => sum += positive
      "norm2" => sum += value * value
      _ => if positive > sum { sum = positive }
    }
  }
  if sum.is_inf() || sum.is_nan() {
    raise sql_error(
      8115,
      "Arithmetic overflow error converting expression to data type float.",
      state=2,
    )
  }
  if option == "norm2" {
    sum.sqrt()
  } else {
    sum
  }
}

///|
pub fn VectorData::normalize(
  self : VectorData,
  kind : String,
) -> VectorData raise SqlError {
  if self.base_type == Float16 {
    raise vector_half_norm_error("vector_normalize")
  }
  let norm = Float::from_double(self.norm(kind)).to_double()
  if norm == 0.0 {
    return self
  }
  {
    base_type: self.base_type,
    components: self.components.map(v => {
      Float::from_double(v / norm).to_double()
    }),
  }
}

///|
fn vector_f32(value : Double) -> Double {
  Float::from_double(value).to_double()
}

///|
// Binary32 products are exact in binary64. TwoSum preserves the residual
// needed when binary64 addition lands on a binary32 rounding midpoint.
// The deliberate midpoint captures in vector-distance-special require this;
// a double multiply/add followed by a float cast double-rounds those cases.
fn vector_fma(a : Double, b : Double, c : Double) -> Double {
  let product = a * b
  let sum = product + c
  let rounded = vector_f32(sum)
  if sum.is_inf() || sum.is_nan() {
    return rounded
  }
  let recovered = sum - product
  let residual = product - (sum - recovered) + (c - recovered)
  if residual == 0.0 || rounded == sum {
    return rounded
  }
  if rounded.is_inf() {
    let threshold = 3.4028235677973366e38
    if sum == threshold && residual < 0.0 {
      return Float::reinterpret_from_uint(0x7f7fffff).to_double()
    }
    if sum == -threshold && residual > 0.0 {
      return -Float::reinterpret_from_uint(0x7f7fffff).to_double()
    }
    return rounded
  }
  let bits = Float::from_double(rounded).reinterpret_as_uint()
  let upward = sum > rounded
  let neighbor = if rounded == 0.0 {
    let smallest = Float::reinterpret_from_uint(1).to_double()
    if upward {
      smallest
    } else {
      -smallest
    }
  } else {
    Float::reinterpret_from_uint(
      if upward == (rounded > 0.0) {
        bits + 1
      } else {
        bits - 1
      },
    ).to_double()
  }
  if neighbor.is_inf() || sum != (rounded + neighbor) / 2.0 {
    return rounded
  }
  if (residual > 0.0) == upward {
    neighbor
  } else {
    rounded
  }
}

///|
// Oracle captures pin both lane layout and reduction order. Cosine uses two
// accumulators per lane; dot/Euclidean use four. All use 32-component blocks.
fn vector_dot(a : Array[Double], b : Array[Double], cosine : Bool) -> Double {
  let registers = if cosine { 2 } else { 4 }
  let accumulators = Array::make(registers * 8, 0.0)
  let full = a.length() / 32 * 32
  for i in 0..<full {
    let lane = i / 8 % registers * 8 + i % 8
    accumulators[lane] = vector_fma(a[i], b[i], accumulators[lane])
  }
  let lanes = Array::make(8, 0.0)
  for i in 0..<8 {
    let first = vector_f32(accumulators[i] + accumulators[i + 8])
    lanes[i] = if cosine {
      first
    } else {
      vector_f32(
        first + vector_f32(accumulators[i + 16] + accumulators[i + 24]),
      )
    }
  }
  for i in full..<a.length() {
    lanes[i % 8] = vector_fma(a[i], b[i], lanes[i % 8])
  }
  for width in [4, 2, 1] {
    for i in 0..<width {
      lanes[i] = vector_f32(lanes[i] + lanes[i + width])
    }
  }
  lanes[0]
}

///|
pub fn VectorData::distance(
  self : VectorData,
  other : VectorData,
  metric : String,
) -> Double raise SqlError {
  let kind = metric.to_lower()
  if !(kind is ("dot" | "euclidean" | "cosine")) {
    raise sql_error(
      42201,
      "The requested distance metric '\{metric}' is not supported by vector_distance. Provide a valid distance metric.",
      state=2,
    )
  }
  if self.dimensions() != other.dimensions() {
    raise sql_error(
      42204,
      "The vector dimensions \{self.dimensions()} and \{other.dimensions()} do not match.",
      state=3,
    )
  }
  if self.base_type != other.base_type {
    raise sql_error(
      42243, "VECTOR_DISTANCE function does not support different base types for vector arguments.",
    )
  }
  let a = self.components
  let b = other.components
  let value = match kind {
    "dot" => -vector_dot(a, b, self.base_type == Float16)
    "euclidean" => {
      let difference = Array::make(a.length(), 0.0)
      for i in 0..<a.length() {
        difference[i] = vector_f32(a[i] - b[i])
      }
      vector_f32(
        vector_dot(difference, difference, self.base_type == Float16).sqrt(),
      )
    }
    _ => {
      let aa = vector_dot(a, a, true)
      let bb = vector_dot(b, b, true)
      if aa == 0.0 || bb == 0.0 {
        1.0
      } else {
        let denominator = vector_f32(
          vector_f32(aa.sqrt()) * vector_f32(bb.sqrt()),
        )
        let distance = vector_f32(
          1.0 - vector_f32(vector_dot(a, b, true) / denominator),
        )
        if distance.is_nan() || distance < 0.0 {
          0.0
        } else if distance > 2.0 {
          2.0
        } else {
          distance
        }
      }
    }
  }
  if value.is_inf() || value.is_nan() {
    raise sql_error(
      8115,
      "Arithmetic overflow error converting expression to data type float.",
      state=2,
    )
  }
  value
}

///|
pub fn VectorData::base(self : VectorData) -> VectorBase {
  self.base_type
}

///|
pub fn vector_base_conversion_error(
  from : VectorBase,
  to : VectorBase,
) -> SqlError {
  sql_error(
    42238,
    "Conversion of vector from data type \{from.name()} to \{to.name()} is not allowed.",
  )
}

///|
pub fn vector_half_norm_error(function : String) -> SqlError {
  sql_error(
    42246,
    "\{function} function does not support vector with base type float16.",
  )
}

///|
// SQL parses binary32 first. Normal binary16 values round away 13 fraction
// bits; subnormals round to units of 2^-24, using nearest/even in both paths.
fn vector_half(value : Double) -> Double raise SqlError {
  let bits = Float::from_double(value).reinterpret_as_uint()
  let magnitude = bits & 0x7fffffff
  let positive = if value < 0.0 { -value } else { value }
  let rounded = if magnitude < 0x38800000 {
    let units = positive * 16777216.0
    let floor = units.to_int()
    let fraction = units - floor.to_double()
    let integer = if fraction > 0.5 || (fraction == 0.5 && floor % 2 == 1) {
      floor + 1
    } else {
      floor
    }
    integer.to_double() / 16777216.0
  } else {
    let rounded_bits = (magnitude + 0xfff + ((magnitude >> 13) & 1)) &
      0xffffe000
    Float::reinterpret_from_uint(rounded_bits).to_double()
  }
  if rounded > 65504.0 {
    raise sql_error(
      42241,
      "Input JSON contains out-of-range values for float16.",
      state=2,
    )
  }
  if rounded == 0.0 {
    0.0
  } else if value < 0.0 {
    -rounded
  } else {
    rounded
  }
}
