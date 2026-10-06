///|
fn base64_decode_error(state : Int) -> @types.SqlError {
  @types.sql_error(9803, "Invalid data for type \"Base64Decode\".", state~)
}

///|
/// Accept both alphabets, optional padding, and SQL's four whitespace bytes.
/// Validate before producing bytes so malformed inputs never yield partial data.
fn sql_base64_decode(s : String) -> Bytes raise @types.SqlError {
  let codes : Array[Int] = []
  let mut padding = false
  let mut ended = false
  for u in s.iter() {
    let n = u.to_int()
    if n == 32 || n == 9 || n == 10 || n == 13 {
      continue
    }
    if ended {
      raise base64_decode_error(23)
    }
    let code = if n >= 65 && n <= 90 {
      n - 65
    } else if n >= 97 && n <= 122 {
      n - 97 + 26
    } else if n >= 48 && n <= 57 {
      n - 48 + 52
    } else if n == 43 || n == 45 {
      62
    } else if n == 47 || n == 95 {
      63
    } else if n == 61 {
      -1
    } else {
      raise base64_decode_error(20)
    }
    if padding {
      if code != -1 {
        raise base64_decode_error(22)
      }
      ended = true
    } else if code == -1 {
      match codes.length() % 4 {
        2 => padding = true
        3 => ended = true
        _ => raise base64_decode_error(21)
      }
    } else {
      codes.push(code)
    }
  }
  let data_len = codes.length()
  if data_len % 4 == 1 {
    raise base64_decode_error(21)
  }
  let bytes : Array[Byte] = []
  let mut bits = 0
  let mut acc = 0
  for i in 0..<data_len {
    acc = (acc << 6) | codes[i]
    bits += 6
    if bits >= 8 {
      bits -= 8
      bytes.push(((acc >> bits) & 255).to_byte())
      acc = acc & ((1 << bits) - 1)
    }
  }
  Bytes::from_array(bytes)
}

///|
fn call_base64(
  name : String,
  values : Array[@types.Value],
) -> @types.Value? raise @types.SqlError {
  match name {
    "BASE64_ENCODE" => {
      guard values[0] is Binary(bytes) else { return Some(Null) }
      let encoded = base64(bytes)
      let url_safe = values.length() == 2 && values[1] is Bit(true)
      Some(
        String(
          if url_safe {
            encoded
            .replace_all(old="+", new="-")
            .replace_all(old="/", new="_")
            .trim_end(chars="=")
            .to_owned()
          } else {
            encoded
          },
        ),
      )
    }
    "BASE64_DECODE" => {
      guard values[0] is String(s) else { return Some(Null) }
      Some(Binary(sql_base64_decode(s)))
    }
    _ => None
  }
}
