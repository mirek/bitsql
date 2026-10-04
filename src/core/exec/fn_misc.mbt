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
        Some(
          @types.varchar_bytes(
            s,
            t.collation().unwrap_or(@types.default_collation),
          ),
        )
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
    "COMPRESS" =>
      match v[0] {
        Null => Null
        String(text) => {
          let raw = if args[0].ty.is_unicode() {
            Bytes::makei(text.length() * 2, i => {
              let u = text.code_unit_at(i / 2).to_int()
              (if i % 2 == 0 { u & 0xFF } else { u >> 8 }).to_byte()
            })
          } else {
            @types.varchar_bytes(
              text,
              args[0].ty.collation().unwrap_or(@types.default_collation),
            )
          }
          Binary(@gzip.gzip_compress(raw[:]))
        }
        Binary(b) => Binary(@gzip.gzip_compress(b[:]))
        _ => raise @types.not_supported("COMPRESS of \{args[0].ty.to_sql()}")
      }
    "DECOMPRESS" =>
      match v[0] {
        Null => Null
        Binary(b) =>
          match @gzip.gzip_decompress(b[:]) {
            Data(out) => Binary(out)
            Incomplete => Null
            Corrupt =>
              raise @types.sql_error(
                9826, "Uncompressed or corrupted data passed as argument to DECOMPRESS builtin.",
              )
          }
        _ => raise @types.not_supported("DECOMPRESS of \{args[0].ty.to_sql()}")
      }
    "GREATEST" | "LEAST" => {
      let mut best : @types.Value = Null
      let coll = e.ty.collation()
      for i, x in v {
        if x is Null {
          continue
        }
        // a max argument longer than the 8000-byte result (bound as
        // varchar(8000) / nvarchar(4000) / varbinary(8000)); any argument,
        // not only the winner (captured probe)
        if args[i].ty
          is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None)) {
          let fits = match (x, e.ty) {
            (String(s), VarChar(Some(n), _) | NVarChar(Some(n), _)) =>
              s.length() <= n
            (Binary(b), VarBinary(Some(n))) => b.length() <= n
            _ => true
          }
          if !fits {
            raise @types.sql_error(
              8152,
              "String or binary data would be truncated.",
              state=10,
            )
          }
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
        // trailing blanks are ignored (captured: 'MD5 ' hashes, ' MD5' is
        // NULL; msduck hashbytes-checksum #016)
        String(s) => s.trim_end(chars=" ").to_owned().to_upper()
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
    "BINARY_CHECKSUM" | "CHECKSUM" => {
      // per argument a 32-bit hash, combined as h = rotl4(h) ^ hash
      // (checksum.mbt); an untyped NULL argument of BINARY_CHECKSUM is
      // skipped (captured: BINARY_CHECKSUM(1, NULL) is 1)
      let binary = name == "BINARY_CHECKSUM"
      let mut h = 0
      for i, x in v {
        if binary && args[i].kind is Lit(Null) && args[i].ty is Int {
          continue
        }
        match checksum_value(x, args[i].ty, binary) {
          Some(k) => h = rotl4(h) ^ k
          None =>
            raise @types.not_supported("\{name} of \{args[i].ty.to_sql()}")
        }
      }
      Int(h)
    }
    _ => return None
  }
  Some(r)
}
