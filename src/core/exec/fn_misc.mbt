// GREATEST/LEAST, ISNUMERIC, HASHBYTES, CHECKSUM, BINARY_CHECKSUM
// (bound in bind/fn_misc.mbt).

///|
fn is_space_unit(c : Int) -> Bool {
  c == 0x20 || (c >= 0x09 && c <= 0x0D)
}

///|
fn is_currency(c : Int) -> Bool {
  c
  is ('$'
  | '\\'
  | 0xA2
  | 0xA3
  | 0xA4
  | 0xA5
  | 0x20AC
  | 0x20A1
  | 0x20A3
  | 0x20A4
  | 0x20A6
  | 0x20A7
  | 0x20A8
  | 0x20A9
  | 0x20AA
  | 0x20AB
  | 0x20AD
  | 0x20AE
  | 0x20B1
  | 0x20B2
  | 0x20B4
  | 0x20B5
  | 0x20B9
  | 0x20BA
  | 0x20BD
  | 0x09F3
  | 0x0E3F
  | 0x17DB
  | 0xFDFC)
}

///|
fn is_digit_unit(c : Int) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
}

///|
/// float syntax: [sign] (digits [. digits] | . digits) [e|d [sign] digits],
/// finite as a double.
fn float_like(s : String) -> Bool {
  let n = s.length()
  let at = (i : Int) => if i < n { s.code_unit_at(i).to_int() } else { -1 }
  let mut i = 0
  if at(i) == '+'.to_int() || at(i) == '-'.to_int() {
    i += 1
  }
  let mut digits = 0
  while is_digit_unit(at(i)) {
    i += 1
    digits += 1
  }
  if at(i) == '.'.to_int() {
    i += 1
    while is_digit_unit(at(i)) {
      i += 1
      digits += 1
    }
  }
  if digits == 0 {
    return false
  }
  let e = at(i)
  if e is ('e' | 'E' | 'd' | 'D') {
    i += 1
    if at(i) == '+'.to_int() || at(i) == '-'.to_int() {
      i += 1
    }
    let mut ed = 0
    while is_digit_unit(at(i)) {
      i += 1
      ed += 1
    }
    if ed == 0 {
      return false
    }
  }
  if i != n {
    return false
  }
  let normalized = s.replace_all(old="d", new="e").replace_all(old="D", new="e")
  match @types.parse_float_text(normalized) {
    Some(d) => !d.is_inf() && !d.is_nan()
    None => false
  }
}

///|
/// money syntax: optional currency symbol and sign in either order, then
/// digits and commas with an optional decimal point (captured: '-', ',',
/// '.', '$' and '1,000' are numeric).
fn money_like(s : String) -> Bool {
  let n = s.length()
  let at = (i : Int) => if i < n { s.code_unit_at(i).to_int() } else { -1 }
  let mut i = 0
  let mut seen_sign = false
  let mut seen_cur = false
  for k in 0..<2 {
    ignore(k)
    if !seen_cur && is_currency(at(i)) {
      seen_cur = true
      i += 1
    } else if !seen_sign && (at(i) == '+'.to_int() || at(i) == '-'.to_int()) {
      seen_sign = true
      i += 1
    }
  }
  // captured: '- 5' is numeric (spaces may follow the sign)
  if seen_sign || seen_cur {
    while at(i) == ' '.to_int() {
      i += 1
    }
  }
  while is_digit_unit(at(i)) || at(i) == ','.to_int() {
    i += 1
  }
  if at(i) == '.'.to_int() {
    i += 1
    while is_digit_unit(at(i)) {
      i += 1
    }
  }
  i == n && n > 0
}

///|
fn isnumeric_text(s : String) -> Bool {
  let mut a = 0
  let mut b = s.length()
  while a < b && is_space_unit(s.code_unit_at(a).to_int()) {
    a += 1
  }
  while b > a && is_space_unit(s.code_unit_at(b - 1).to_int()) {
    b -= 1
  }
  if a == b {
    return false
  }
  let t = s.unsafe_substring(start=a, end=b)
  float_like(t) || money_like(t)
}

///|
fn hash_input(v : @types.Value, t : @types.SqlType) -> Bytes? {
  match v {
    Binary(b) => Some(b)
    String(s) =>
      if t.is_unicode() {
        Some(
          Bytes::makei(s.length() * 2, i => {
            let u = s.code_unit_at(i / 2).to_int()
            (if i % 2 == 0 { u & 0xFF } else { u >> 8 }).to_byte()
          }),
        )
      } else {
        Some(@types.cp1252_bytes(s))
      }
    _ => None
  }
}

///|
fn rotl4(h : Int) -> Int {
  (h << 4) | (h.reinterpret_as_uint() >> 28).reinterpret_as_int()
}

///|
fn call_misc(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value? raise @types.SqlError {
  let r : @types.Value = match name {
    "GREATEST" | "LEAST" => {
      let mut best : @types.Value = Null
      let coll = e.ty.collation()
      for x in v {
        if x is Null {
          continue
        }
        if best is Null {
          best = x
          continue
        }
        match @types.compare(x, best, collation?=coll) {
          Some(c) =>
            if (name == "GREATEST" && c > 0) || (name == "LEAST" && c < 0) {
              best = x
            }
          None => ()
        }
      }
      best
    }
    "ISNUMERIC" =>
      match v[0] {
        Null => Int(0)
        String(s) => Int(if isnumeric_text(s) { 1 } else { 0 })
        _ => Int(1)
      }
    "HASHBYTES" => {
      let alg = match v[0] {
        String(s) => s.to_upper()
        _ => return Some(Null)
      }
      guard hash_input(v[1], args[1].ty) is Some(data) else {
        return Some(Null)
      }
      match alg {
        "MD4" => Binary(md4(data))
        "MD5" => Binary(md5(data))
        "SHA" | "SHA1" => Binary(sha1(data))
        "SHA2_256" => Binary(sha256(data))
        "SHA2_512" => Binary(sha512(data))
        // captured: MD2 and unknown algorithms give NULL
        _ => Null
      }
    }
    "BINARY_CHECKSUM" => {
      // h = rotl4(h) ^ unit over: varchar bytes as signed chars (captured:
      // 'é' is -23), nvarchar UTF-16 units, binary bytes, integers whole
      // (256 is 256); trailing spaces do not count (char(4) 'ab' = 'ab').
      let mut h = 0
      for i, x in v {
        match x {
          Null => ()
          String(s) => {
            let s = rtrim_spaces(s)
            if args[i].ty.is_unicode() {
              for k in 0..<s.length() {
                h = rotl4(h) ^ s.code_unit_at(k).to_int()
              }
            } else {
              for b in @types.cp1252_bytes(s) {
                let c = b.to_int()
                h = rotl4(h) ^ (if c >= 128 { c - 256 } else { c })
              }
            }
          }
          Binary(bs) =>
            for b in bs {
              h = rotl4(h) ^ b.to_int()
            }
          TinyInt(n) | SmallInt(n) | Int(n) => h = rotl4(h) ^ n
          BigInt(n) => h = rotl4(h) ^ (n.to_int() ^ (n >> 32).to_int())
          _ =>
            raise @types.not_supported(
              "BINARY_CHECKSUM of \{args[i].ty.to_sql()}",
            )
        }
      }
      Int(h)
    }
    "CHECKSUM" => {
      // integers only: their value, bigint as high ^ low word (captured:
      // CHECKSUM(CAST(-1 AS bigint)) is 0, 4294967296 is 1); text hashes
      // collation sort keys and is not emulated
      let mut h = 0
      for i, x in v {
        let k = match x {
          Null => 0
          TinyInt(n) | SmallInt(n) | Int(n) => n
          BigInt(n) => n.to_int() ^ (n >> 32).to_int()
          _ => raise @types.not_supported("CHECKSUM of \{args[i].ty.to_sql()}")
        }
        h = rotl4(h) ^ k
      }
      Int(h)
    }
    _ => return None
  }
  Some(r)
}
