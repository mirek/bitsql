///|
/// printf-style RAISERROR message formatting: %d %i %u %s %x %X %o %%, with
/// optional flags, width and precision (`*` takes an argument).
pub fn format_raiserror(
  fmt : String,
  args : Array[@types.Value],
  types? : Array[@types.SqlType?] = [],
) -> String raise @types.SqlError {
  let out = StringBuilder()
  let mut ai = 0
  let n = fmt.length()
  let mut i = 0
  // Argument types must suit their specification (captured: msduck
  // raiserror-format-types/-extra): None marks an untyped NULL literal.
  // Without `types` (tests), nothing is checked.
  let checked = !types.is_empty()
  let mismatch = (k : Int) => {
    @types.sql_error(
      2786,
      "The data type of substitution parameter \{k + 1} does not match the expected type of the format specification.",
    )
  }
  let next_arg = () => {
    let v = if ai < args.length() { Some(args[ai]) } else { None }
    ai += 1
    v
  }
  let type_at = (k : Int) => if k < types.length() { types[k] } else { None }
  // `*` width/precision: a non-NULL tinyint/smallint/int
  let next_star = () => {
    let k = ai
    let v = next_arg()
    if checked {
      match (type_at(k), v) {
        (Some(TinyInt | SmallInt | Int), Some(x)) if !(x is Null) => ()
        (_, None) => ()
        _ => raise mismatch(k)
      }
    }
    v
  }
  while i < n {
    let c = fmt.code_unit_at(i).to_int()
    if c != '%'.to_int() {
      out.write_char(c.unsafe_to_char())
      i += 1
      continue
    }
    if i + 1 < n && fmt.code_unit_at(i + 1).to_int() == '%'.to_int() {
      out.write_char('%')
      i += 2
      continue
    }
    // %[flags][width][.precision][h|l]type
    let start = i
    i += 1
    let mut left = false
    let mut zero = false
    let mut plus = false
    let mut space = false
    let mut hash = false
    while i < n {
      match fmt.code_unit_at(i).to_int().unsafe_to_char() {
        '-' => left = true
        '0' => zero = true
        '+' => plus = true
        ' ' => space = true
        '#' => hash = true
        _ => break
      }
      i += 1
    }
    let mut width = -1
    if i < n && fmt.code_unit_at(i).to_int() == '*'.to_int() {
      width = match next_star() {
        Some(v) => v.as_int64().unwrap_or(0L).to_int()
        None => 0
      }
      i += 1
    } else {
      while i < n &&
            fmt.code_unit_at(i).to_int() >= '0'.to_int() &&
            fmt.code_unit_at(i).to_int() <= '9'.to_int() {
        width = @cmp.maximum(width, 0) * 10 +
          (fmt.code_unit_at(i).to_int() - '0'.to_int())
        i += 1
      }
    }
    let mut precision = -1
    if i < n && fmt.code_unit_at(i).to_int() == '.'.to_int() {
      i += 1
      precision = 0
      if i < n && fmt.code_unit_at(i).to_int() == '*'.to_int() {
        precision = match next_star() {
          Some(v) => v.as_int64().unwrap_or(0L).to_int()
          None => 0
        }
        i += 1
      } else {
        while i < n &&
              fmt.code_unit_at(i).to_int() >= '0'.to_int() &&
              fmt.code_unit_at(i).to_int() <= '9'.to_int() {
          precision = precision * 10 +
            (fmt.code_unit_at(i).to_int() - '0'.to_int())
          i += 1
        }
      }
    }
    // 'h' (16-bit), 'l' (32-bit, as none), 'I64' (64-bit)
    let mut prefix = ""
    while i < n &&
          (
            fmt.code_unit_at(i).to_int() == 'h'.to_int() ||
            fmt.code_unit_at(i).to_int() == 'l'.to_int() ||
            fmt.code_unit_at(i).to_int() == 'I'.to_int()
          ) {
      if fmt.code_unit_at(i).to_int() == 'I'.to_int() &&
        i + 2 < n &&
        fmt.unsafe_substring(start=i, end=i + 3) == "I64" {
        prefix = "I64"
        i += 3
        continue
      }
      prefix = prefix + fmt.unsafe_substring(start=i, end=i + 1)
      i += 1
    }
    if i >= n {
      // a specification without a type (captured: 'abc%' → 2787 '%')
      raise @types.sql_error(
        2787,
        "Invalid format specification: '\{fmt.unsafe_substring(start~, end=n)}'.",
      )
    }
    let ty = fmt.code_unit_at(i).to_int().unsafe_to_char()
    i += 1
    // Captured (msduck raiserror-format*): unknown types and size prefixes on
    // %s are error 2787 naming the whole specification.
    let valid = match ty {
      'd' | 'i' | 'u' | 'x' | 'X' | 'o' => true
      's' => prefix == "" || prefix == "l"
      _ => false
    }
    if !valid {
      // the message quotes the rest of the format string (captured:
      // '%c|%f' for N'%c|%f')
      let spec = fmt.unsafe_substring(start~, end=n)
      raise @types.sql_error(2787, "Invalid format specification: '\{spec}'.")
    }
    let k = ai
    let arg = next_arg()
    if checked && arg is Some(_) {
      let ok = match (ty, type_at(k)) {
        (_, None) => true // NULL literal prints (null)
        ('s', Some(t)) =>
          t is (Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _))
        (_, Some(t)) =>
          match prefix {
            "h" | "hh" => t is (TinyInt | SmallInt)
            "I64" => t is BigInt
            _ => t is (TinyInt | SmallInt | Int)
          }
      }
      if !ok {
        raise mismatch(k)
      }
    }
    if arg is (None | Some(Null)) {
      // NULL arguments print "(null)" ignoring width and precision (captured)
      out.write_string("(null)")
      continue
    }
    let body = match (ty, arg) {
      (_, None) => "(null)"
      (_, Some(Null)) => "(null)"
      ('d' | 'i', Some(v)) => {
        let raw = v.as_int64().unwrap_or(0L)
        // %hd: 16-bit
        let x = if prefix.contains("h") { raw << 48 >> 48 } else { raw }
        if precision == 0 && x == 0L {
          // C semantics: %.0d of zero prints no digits (captured)
          ""
        } else {
          let digits = x.abs().to_string()
          let digits = if precision > digits.length() {
            "0".repeat(@cmp.minimum(precision, 4096) - digits.length()) + digits
          } else {
            digits
          }
          let sign = if x < 0L {
            "-"
          } else if plus {
            "+"
          } else if space {
            " "
          } else {
            ""
          }
          sign + digits
        }
      }
      ('u', Some(v)) => {
        let x = v.as_int64().unwrap_or(0L)
        let u = x.to_int().reinterpret_as_uint()
        // %hu: 16-bit (captured: -1 prints 65535)
        (if prefix.contains("h") { u & 0xFFFFU } else { u }).to_string()
      }
      ('x' | 'X' | 'o', Some(v)) => {
        let x0 = v.as_int64().unwrap_or(0L).to_int().reinterpret_as_uint()
        let x = if prefix.contains("h") { x0 & 0xFFFFU } else { x0 }
        let radix = if ty == 'o' { 8 } else { 16 }
        let s = x.to_string(radix~)
        let s = if ty == 'X' { s.to_upper() } else { s }
        let prefix = if hash && x != 0 {
          match ty {
            'x' => "0x"
            'X' => "0X"
            _ => "0"
          }
        } else {
          ""
        }
        prefix + s
      }
      ('s', Some(String(s))) =>
        if precision >= 0 && precision < s.length() {
          s.unsafe_substring(start=0, end=precision)
        } else {
          s
        }
      (_, Some(v)) => debug_text(v)
    }
    // RAISERROR messages are limited to 2047 characters; clamp padding so a
    // huge width never allocates (String::repeat aborts on overflow).
    let pad = @cmp.minimum(width, 4096) - body.length()
    if pad > 0 {
      if left {
        out.write_string(body)
        out.write_string(" ".repeat(pad))
      } else if zero && ty != 's' {
        let (sign, rest) = if body.has_prefix("-") || body.has_prefix("+") {
          (
            body.unsafe_substring(start=0, end=1),
            body.unsafe_substring(start=1, end=body.length()),
          )
        } else {
          ("", body)
        }
        out.write_string(sign)
        out.write_string("0".repeat(pad))
        out.write_string(rest)
      } else {
        out.write_string(" ".repeat(pad))
        out.write_string(body)
      }
    } else {
      out.write_string(body)
    }
  }
  // messages are limited to 2047 characters: 2044 + "..." (captured)
  let msg = out.to_string()
  if msg.length() > 2047 {
    msg.unsafe_substring(start=0, end=2044) + "..."
  } else {
    msg
  }
}

///|
fn debug_text(v : @types.Value) -> String {
  match v {
    String(s) => s
    other =>
      match other.as_int64() {
        Some(i) => i.to_string()
        None => ""
      }
  }
}
