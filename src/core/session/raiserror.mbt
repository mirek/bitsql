///|
/// printf-style RAISERROR message formatting: %d %i %u %s %x %X %o %%, with
/// optional flags, width and precision (`*` takes an argument).
pub fn format_raiserror(
  fmt : String,
  args : Array[@types.Value],
) -> String raise @types.SqlError {
  let out = StringBuilder()
  let mut ai = 0
  let n = fmt.length()
  let mut i = 0
  let next_arg = () => {
    let v = if ai < args.length() { Some(args[ai]) } else { None }
    ai += 1
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
      width = match next_arg() {
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
        precision = match next_arg() {
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
    let mut size_prefix = false
    while i < n &&
          (
            fmt.code_unit_at(i).to_int() == 'h'.to_int() ||
            fmt.code_unit_at(i).to_int() == 'l'.to_int() ||
            fmt.code_unit_at(i).to_int() == 'I'.to_int()
          ) {
      size_prefix = true
      i += 1
    }
    if i >= n {
      out.write_string(fmt.unsafe_substring(start~, end=n))
      break
    }
    let ty = fmt.code_unit_at(i).to_int().unsafe_to_char()
    i += 1
    // Captured (msduck raiserror-format*): unknown types and size prefixes on
    // %s are error 2787 naming the whole specification.
    let valid = match ty {
      'd' | 'i' | 'u' | 'x' | 'X' | 'o' => true
      's' => !size_prefix
      _ => false
    }
    if !valid {
      let spec = fmt.unsafe_substring(start~, end=i)
      raise @types.sql_error(2787, "Invalid format specification: '\{spec}'.")
    }
    let arg = next_arg()
    let body = match (ty, arg) {
      (_, None) => "(null)"
      (_, Some(Null)) => "(null)"
      ('d' | 'i', Some(v)) => {
        let x = v.as_int64().unwrap_or(0L)
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
      ('u', Some(v)) => {
        let x = v.as_int64().unwrap_or(0L)
        x.to_int().reinterpret_as_uint().to_string()
      }
      ('x' | 'X' | 'o', Some(v)) => {
        let x = v.as_int64().unwrap_or(0L).to_int().reinterpret_as_uint()
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
  out.to_string()
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
