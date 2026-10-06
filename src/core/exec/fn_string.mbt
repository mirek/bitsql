// String built-ins (bound in bind/fn_string.mbt). Arguments arrive
// converted to character types, except binary values, which are decoded as
// code page 1252 text (captured: LEFT(0x008041, 2) is NUL + '€').

///|
/// Text of a string argument (None for NULL).
/// Dates and times convert under the session language (captured: msduck
/// temporal-guid-format, CONCAT of a datetime under French is 'févr 28 …').
fn text(
  v : @types.Value,
  t : @types.SqlType,
  dates? : @types.DateSettings = @types.default_date_settings,
) -> String? raise @types.SqlError {
  match v {
    Null => None
    String(s) => Some(s)
    Binary(b) => Some(@types.cp1252_string(b))
    other =>
      match
        @types.cast(other, t, NVarChar(None, @types.default_collation), dates~) {
        String(s) => Some(s)
        _ => None
      }
  }
}

///|
/// An integer argument: decimals, money and floats truncate toward zero;
/// values outside int raise 8115 state 2 (captured for RIGHT/REPLICATE).
fn int_of(v : @types.Value) -> Int64? raise @types.SqlError {
  let n = match v {
    Null => return None
    // integers directly (the decimal route below gives the same value and
    // the same overflow outside int)
    TinyInt(x) | SmallInt(x) | Int(x) => x.to_int64()
    BigInt(x) =>
      if x < -2147483648L || x > 2147483647L {
        raise @types.overflow_expression(Int)
      } else {
        x
      }
    Float(d) =>
      if d.is_nan() || d.is_inf() || d.abs() >= 9.0e18 {
        raise @types.overflow_expression(Int)
      } else {
        d.trunc().to_int64()
      }
    _ =>
      match v.as_decimal() {
        Some(x) => {
          let b = x.trunc_to_bigint()
          if b < @bigint.BigInt::from_int(-2147483648) ||
            b > @bigint.BigInt::from_int(2147483647) {
            raise @types.overflow_expression(Int)
          }
          b.to_int64()
        }
        None => return None
      }
  }
  if n < -2147483648L || n > 2147483647L {
    raise @types.overflow_expression(Int)
  }
  Some(n)
}

///|
fn collation_of(t : @types.SqlType) -> @types.Collation {
  t.collation().unwrap_or(@types.default_collation)
}

///|
/// Truncates a non-max result to its type's capacity (8000 bytes, 4000
/// UTF-16 units without splitting a surrogate pair; captured for
/// REPLICATE).
/// Concatenation cut to the result type: a piece that does not fit is cut
/// by code units but never inside its own surrogate pair, while pairs formed
/// across pieces may be split (captured: msduck concat-boundary, 3999 'a' +
/// N'😀' keeps 3999 units, 3999 'a' + NCHAR(0xD83D) + NCHAR(0xDE00) keeps
/// the high surrogate).
fn cap_pieces(pieces : Array[String], t : @types.SqlType) -> String {
  let cap = match t {
    VarChar(Some(_), _) | Char(_, _) => 8000
    NVarChar(Some(_), _) | NChar(_, _) => 4000
    _ => return pieces.iter().fold(init="", (a, b) => a + b)
  }
  let out = StringBuilder()
  let mut len = 0
  for p in pieces {
    if len + p.length() <= cap {
      out.write_string(p)
      len += p.length()
      continue
    }
    let mut take = cap - len
    if take > 0 &&
      p.code_unit_at(take - 1).to_int() >= 0xD800 &&
      p.code_unit_at(take - 1).to_int() <= 0xDBFF &&
      p.code_unit_at(take).to_int() >= 0xDC00 &&
      p.code_unit_at(take).to_int() <= 0xDFFF {
      take -= 1
    }
    out.write_string(p.unsafe_substring(start=0, end=take))
    break
  }
  out.to_string()
}

///|
fn cap_text(s : String, t : @types.SqlType) -> String {
  let cap = match t {
    VarChar(Some(_), _) | Char(_, _) => 8000
    NVarChar(Some(_), _) | NChar(_, _) => 4000
    _ => return s
  }
  if s.length() <= cap {
    return s
  }
  let mut n = cap
  let last = s.code_unit_at(n - 1).to_int()
  if last >= 0xD800 && last <= 0xDBFF {
    let next = s.code_unit_at(n).to_int()
    if next >= 0xDC00 && next <= 0xDFFF {
      n -= 1
    }
  }
  s.unsafe_substring(start=0, end=n)
}

///|
/// Simple case mapping of a UTF-16 unit: ASCII, Latin-1, Latin Extended-A,
/// Greek and Cyrillic (captured: LOWER(N'ÀBC') is 'àbc'; scripts beyond
/// these are left unchanged, unverified).
fn case_unit(c : Int, upper : Bool) -> Int {
  let pair = (lo_even : Bool) => {
    // Latin Extended-A pairs: upper/lower alternate
    let is_upper = (c % 2 == 0) == lo_even
    if upper && !is_upper {
      c - 1
    } else if !upper && is_upper {
      c + 1
    } else {
      c
    }
  }
  if upper {
    if c >= 0x61 && c <= 0x7A {
      return c - 32
    }
    if c >= 0xE0 && c <= 0xFE && c != 0xF7 {
      return c - 32
    }
    if c == 0xFF {
      return 0x178
    }
    if c >= 0x3B1 && c <= 0x3C9 {
      return if c == 0x3C2 { 0x3A3 } else { c - 32 }
    }
    if c >= 0x430 && c <= 0x44F {
      return c - 32
    }
    if c >= 0x450 && c <= 0x45F {
      return c - 80
    }
  } else {
    if c >= 0x41 && c <= 0x5A {
      return c + 32
    }
    if c >= 0xC0 && c <= 0xDE && c != 0xD7 {
      return c + 32
    }
    if c == 0x178 {
      return 0xFF
    }
    if c >= 0x391 && c <= 0x3A9 && c != 0x3A2 {
      return c + 32
    }
    if c >= 0x410 && c <= 0x42F {
      return c + 32
    }
    if c >= 0x400 && c <= 0x40F {
      return c + 80
    }
  }
  if (c >= 0x100 && c <= 0x137) || (c >= 0x14A && c <= 0x177) {
    return pair(true)
  }
  if (c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E) {
    return pair(false)
  }
  c
}

///|
fn map_case(s : String, upper : Bool) -> String {
  let out = StringBuilder()
  for i in 0..<s.length() {
    out.write_char(
      case_unit(s.code_unit_at(i).to_int(), upper).unsafe_to_char(),
    )
  }
  out.to_string()
}

///|
/// The characters of a string: code units, or under `_SC` collations
/// surrogate pairs kept together.
fn text_chars(s : String, sc : Bool) -> Array[String] {
  let out = []
  let mut i = 0
  while i < s.length() {
    let u = s.code_unit_at(i).to_int()
    let w = if sc &&
      u >= 0xD800 &&
      u <= 0xDBFF &&
      i + 1 < s.length() &&
      s.code_unit_at(i + 1).to_int() >= 0xDC00 &&
      s.code_unit_at(i + 1).to_int() <= 0xDFFF {
      2
    } else {
      1
    }
    out.push(s.unsafe_substring(start=i, end=i + w))
    i += w
  }
  out
}

///|
fn unit_str(s : String, i : Int) -> String {
  s.unsafe_substring(start=i, end=i + 1)
}

///|
fn is_spaces(s : String) -> Bool {
  s.length() > 0 && s.iter().all(c => c == ' ')
}

///|
/// Does code unit `c` belong to the TRIM character set under `coll`? A unit
/// matches when it compares equal to any substring of the set, which
/// handles expansions and decompositions (captured: 'ß' is trimmed by 'ss',
/// 'é' by 'e' + U+0301). Spaces only ever match a literal space (padding
/// rules would otherwise equate ignorable characters with ' ').
fn in_trim_set(
  c : String,
  set : String,
  coll : @types.Collation,
  ansi : Bool,
) -> Bool {
  let n = set.length()
  for i in 0..<n {
    for j in (i + 1)..<=n {
      let sub = set.unsafe_substring(start=i, end=j)
      if c == " " || is_spaces(sub) {
        if c == " " && sub == " " {
          return true
        }
      } else if @types.compare_strings(c, sub, coll, ansi~) == 0 {
        return true
      }
    }
  }
  false
}

///|
fn trim_text(
  s : String,
  set : String?,
  left : Bool,
  right : Bool,
  coll : @types.Collation,
  ansi : Bool,
) -> String {
  let hit = (i : Int) => {
    match set {
      None => s.code_unit_at(i).to_int() == 0x20
      Some(chars) => in_trim_set(unit_str(s, i), chars, coll, ansi)
    }
  }
  let mut a = 0
  let mut b = s.length()
  if left {
    while a < b && hit(a) {
      a += 1
    }
  }
  if right {
    while b > a && hit(b - 1) {
      b -= 1
    }
  }
  s.unsafe_substring(start=a, end=b)
}

///|
/// Case-folding equality of two code units under a collation (TRANSLATE,
/// REPLACE, CHARINDEX use the collation's case sensitivity).
fn units_equal(
  a : String,
  b : String,
  coll : @types.Collation,
  ansi : Bool,
) -> Bool {
  a == b || @types.compare_strings(a, b, coll, ansi~) == 0
}

///|
fn temporal_bytes(scale : Int, base : Int) -> Int {
  base + (if scale <= 2 { 0 } else if scale <= 4 { 1 } else { 2 })
}

///|
fn datalength(v : @types.Value, t : @types.SqlType) -> Int64? {
  let n = match v {
    Null => return None
    String(s) =>
      if t.is_unicode() {
        s.length() * 2
      } else if collation_of(t).utf8() {
        @types.utf8_length(s)
      } else {
        s.length()
      }
    Binary(b) => b.length()
    Bit(_) | TinyInt(_) => 1
    SmallInt(_) => 2
    Int(_) | Date(_) => if v is Date(_) { 3 } else { 4 }
    BigInt(_) | DateTime(_, _) => 8
    SmallDateTime(_, _) => 4
    Money(_) => if t is SmallMoney { 4 } else { 8 }
    Float(_) => if t is Real { 4 } else { 8 }
    Guid(_) => 16
    // by magnitude, not declared precision (captured: DATALENGTH of
    // CAST(12345678901234567890 AS decimal(38,0)) is 9)
    Decimal(d) => @types.decimal_storage_bytes(d)
    // the base value's bytes (captured: variant/basics.sql)
    Variant(inner, base) => @types.variant_data_length(inner, base)
    // the binder rejects DATALENGTH(xml): SQL Server reports the size of
    // its internal binary XML form
    Xml(_) => return None
    Time(_) =>
      match t {
        Time(s) => temporal_bytes(s, 3)
        _ => 5
      }
    DateTime2(_) =>
      match t {
        DateTime2(s) => temporal_bytes(s, 6)
        _ => 8
      }
    DateTimeOffset(_, _) =>
      match t {
        DateTimeOffset(s) => temporal_bytes(s, 8)
        _ => 10
      }
  }
  Some(n.to_int64())
}

///|
/// Collation for a two-operand search: a case-sensitive or binary
/// collation on either side wins (captured: PATINDEX('%b%' COLLATE
/// Latin1_General_CS_AS, 'ABC') is 0); otherwise the searched string's.
fn pair_collation(a : @types.SqlType, b : @types.SqlType) -> @types.Collation {
  let ca = collation_of(a)
  let cb = collation_of(b)
  let strict = (c : @types.Collation) => {
    c.case_sensitive || !(c.kind is Linguistic)
  }
  if strict(ca) && !strict(cb) {
    ca
  } else {
    cb
  }
}

///|
/// 537 state 2, shared by LEFT and SUBSTRING at run time (captured).
fn substring_length_error() -> @types.SqlError {
  @types.sql_error(
    537,
    "Invalid length parameter passed to the LEFT or SUBSTRING function.",
    state=2,
  )
}

///|
fn soundex_code(c : Int) -> Int {
  match c.unsafe_to_char() {
    'B' | 'F' | 'P' | 'V' => 1
    'C' | 'G' | 'J' | 'K' | 'Q' | 'S' | 'X' | 'Z' => 2
    'D' | 'T' => 3
    'L' => 4
    'M' | 'N' => 5
    'R' => 6
    _ => 0
  }
}

///|
/// Letters for SOUNDEX, which reads its input as code page 1252: ASCII
/// letters and the bytes 0xC0-0xFF except × and ÷ (captured: 'ébc' is
/// É120, non-ASCII letters code like vowels; Š, Œ, Ÿ (0x8A, 0x8C, 0x9F)
/// end the input: msduck soundex-difference #009).
fn is_soundex_letter(c : Int) -> Bool {
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 0xC0 && c <= 0xFF && c != 0xD7 && c != 0xF7)
}

///|
/// SQL Server's SOUNDEX code: lower-case h and w separate like vowels
/// (captured: Ashcraft is A226), the first non-letter ends the input ('ab-c' is A100,
/// a non-letter first character gives 0000). `dedupe_first` drops a code
/// equal to the first letter's (SOUNDEX: Pfister is P236); DIFFERENCE
/// compares codes built without that rule (captured: DIFFERENCE('Pfister',
/// 'Fister') is 2, consistent with P123 vs F236).
fn soundex_with(
  s0 : String,
  dedupe_first : Bool,
  legacy? : Bool = false,
) -> String {
  // nvarchar input converts to varchar first (best fit: 'Łódź' is L320,
  // fullwidth letters read as ASCII)
  let s = @types.to_cp1252(s0)
  if s.length() == 0 || !is_soundex_letter(s.code_unit_at(0).to_int()) {
    return "0000"
  }
  let first = case_unit(s.code_unit_at(0).to_int(), true)
  let out = StringBuilder()
  out.write_char(first.unsafe_to_char())
  let mut last = if dedupe_first { soundex_code(first) } else { 0 }
  let mut count = 1
  let mut i = 1
  while i < s.length() && count < 4 {
    let c = s.code_unit_at(i).to_int()
    if !is_soundex_letter(c) {
      break
    }
    // upper-case H and W are skipped without separating equal codes, while
    // lower-case h and w separate like vowels (captured: 'BHB' is B000,
    // 'Bhb' B100, Ashcraft A226; msduck soundex-difference #009)
    if !legacy && (c == 'H'.to_int() || c == 'W'.to_int()) {
      i += 1
      continue
    }
    let code = soundex_code(case_unit(c, true))
    if code != 0 && code != last {
      out.write_char(('0'.to_int() + code).unsafe_to_char())
      count += 1
    }
    last = code
    i += 1
  }
  while count < 4 {
    out.write_char('0')
    count += 1
  }
  out.to_string()
}

///|
fn soundex(s : String) -> String {
  soundex_with(s, true)
}

///|
/// DIFFERENCE(a, b): +1 when the first letters match; then +3 when a's
/// three digits occur in b's, else +2 when either two-digit run of a does,
/// else +1 per digit of a found in b's digits. Fits all 26 captured pairs,
/// including the asymmetric DIFFERENCE('Washington', 'Washer') = 3 vs 2;
/// other inputs are unverified.
fn difference(a : String, b : String, legacy? : Bool = false) -> Int {
  let x = soundex_with(a, false, legacy~)
  let y = soundex_with(b, false, legacy~)
  let mut score = if x.code_unit_at(0) == y.code_unit_at(0) { 1 } else { 0 }
  let xt = x.unsafe_substring(start=1, end=4)
  let yt = y.unsafe_substring(start=1, end=4)
  if yt.contains(xt) {
    score += 3
  } else if yt.contains(xt.unsafe_substring(start=0, end=2)) ||
    yt.contains(xt.unsafe_substring(start=1, end=3)) {
    score += 2
  } else {
    for i in 0..<3 {
      if yt.contains(xt.unsafe_substring(start=i, end=i + 1)) {
        score += 1
      }
    }
  }
  score
}

///|
/// Collation-aware search: the first position (1-based) at or after `from`
/// where some substring compares equal to `needle`, so expansions and
/// decompositions match (captured: CHARINDEX(N'é', N'cafe' + U+0301) is 4,
/// REPLACE(N'straße', 'ss', 'X') is 'straXe'). Returns (position, length)
/// or None. Plain ASCII under a case-insensitive or binary collation takes
/// a direct scan.
fn coll_find(
  hay : String,
  needle : String,
  from : Int,
  coll : @types.Collation,
  ansi : Bool,
) -> (Int, Int)? {
  if needle.length() == 0 {
    return None
  }
  let start = @cmp.maximum(0, from - 1)
  let ascii = (s : String) => {
    s.iter().all(c => c.to_int() < 0x7F && c.to_int() >= 0x20)
  }
  if !(coll.kind is Linguistic) || (ascii(hay) && ascii(needle)) {
    let ci = coll.kind is Linguistic && !coll.case_sensitive
    let p = index_of(hay, needle, start + 1, ci)
    return if p == 0 { None } else { Some((p, needle.length())) }
  }
  let n = hay.length()
  let window = needle.length() * 3 + 3
  // ignorable code units never take part in a match (captured: CHARINDEX
  // of N'ab' in N'a'+NCHAR(0xAD)+N'b' is 0, of N'b' after a surrogate pair
  // 3, of a surrogate pair 0; msduck charindex-patindex #042-#049)
  let ignored = (k : Int) => @types.collation_ignores(hay[k].to_int(), coll)
  if needle.iter().all(c => @types.collation_ignores(c.to_int(), coll)) {
    return None
  }
  for i in start..<n {
    if ignored(i) {
      continue
    }
    for j in (i + 1)..<=@cmp.minimum(n, i + window) {
      if ignored(j - 1) {
        break
      }
      let sub = hay.unsafe_substring(start=i, end=j)
      if is_spaces(sub) != is_spaces(needle) {
        continue
      }
      if @types.compare_strings(sub, needle, coll, ansi~) == 0 {
        return Some((i + 1, j - i))
      }
    }
  }
  None
}

///|
fn string_escape_json(s : String) -> String {
  let out = StringBuilder()
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    match c {
      0x22 => out.write_string("\\\"")
      0x5C => out.write_string("\\\\")
      0x2F => out.write_string("\\/")
      0x08 => out.write_string("\\b")
      0x0C => out.write_string("\\f")
      0x0A => out.write_string("\\n")
      0x0D => out.write_string("\\r")
      0x09 => out.write_string("\\t")
      _ =>
        if c < 0x20 {
          let h = c.to_string(radix=16)
          out.write_string("\\u00")
          if h.length() < 2 {
            out.write_char('0')
          }
          out.write_string(h)
        } else {
          out.write_char(c.unsafe_to_char())
        }
    }
  }
  out.to_string()
}

///|
fn quotename(s : String, q : String) -> String? {
  if s.length() > 128 {
    return None
  }
  // captured (msduck quotename, probes): an empty delimiter means '[';
  // a NUL delimiter returns the input unquoted (an empty input NULL);
  // otherwise an input containing NUL is NULL
  let first = if q.length() == 0 { 0x5B } else { q.code_unit_at(0).to_int() }
  if first == 0 {
    return if s.length() == 0 { None } else { Some(s) }
  }
  if s.contains_char('\u{0}') {
    return None
  }
  let (open, close) = match first {
    '[' | ']' => ('[', ']')
    '\'' => ('\'', '\'')
    '"' => ('"', '"')
    '(' | ')' => ('(', ')')
    '<' | '>' => ('<', '>')
    '{' | '}' => ('{', '}')
    '`' => ('`', '`')
    _ => return None
  }
  let out = StringBuilder()
  out.write_char(open)
  for c in s {
    out.write_char(c)
    if c == close {
      out.write_char(c)
    }
  }
  out.write_char(close)
  Some(out.to_string())
}

///|
fn call_string(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
  dates? : @types.DateSettings = @types.default_date_settings,
) -> @types.Value? raise @types.SqlError {
  let any_null = v.iter().any(x => x is Null)
  let str = (i : Int) => text(v[i], args[i].ty, dates~)
  let r : @types.Value = match name {
    "CONCAT_OPERATOR" => {
      if any_null {
        return Some(Null)
      }
      match (v[0], v[1]) {
        (Binary(a), Binary(b)) => {
          let bytes = a + b
          let limit = match e.ty {
            VarBinary(Some(n)) | Binary(n) => n
            _ => bytes.length()
          }
          Binary(bytes[0:@cmp.minimum(limit, bytes.length())].to_owned())
        }
        _ => {
          guard str(0) is Some(a) && str(1) is Some(b) else {
            return Some(Null)
          }
          @types.cast(
            String(a + b),
            NVarChar(None, collation_of(e.ty)),
            e.ty,
            dates~,
          )
        }
      }
    }
    "LEN" =>
      match str(0) {
        // `_SC` collations count a surrogate pair as one character
        // (captured: settings/utf8, LEN(N'é😀') is 2)
        Some(s) =>
          int_result(
            e.ty,
            (if collation_of(args[0].ty).supplementary() {
              code_points(rtrim_spaces(s))
            } else {
              rtrim_spaces(s).length()
            }).to_int64(),
          )
        None => Null
      }
    "DATALENGTH" =>
      match datalength(v[0], args[0].ty) {
        Some(n) => int_result(e.ty, n)
        None => Null
      }
    "UPPER" | "LOWER" | "REVERSE" =>
      match str(0) {
        Some(s) =>
          String(
            match name {
              // captured per collation version: msduck unicode-case
              "UPPER" | "LOWER" if args[0].ty.is_unicode() ||
                collation_of(args[0].ty).utf8() =>
                @types.case_map(s, name == "UPPER", collation_of(args[0].ty))
              "UPPER" => map_case(s, true)
              "LOWER" => map_case(s, false)
              _ => {
                // UTF-16 code units are reversed one by one (captured:
                // REVERSE(N'a🦆b') swaps the surrogate halves); `_SC`
                // collations keep a pair together (captured: settings/utf8)
                let sc = collation_of(args[0].ty).supplementary()
                let out = StringBuilder()
                let mut i = s.length() - 1
                while i >= 0 {
                  let u = s.code_unit_at(i).to_int()
                  if sc &&
                    u >= 0xDC00 &&
                    u <= 0xDFFF &&
                    i > 0 &&
                    s.code_unit_at(i - 1).to_int() >= 0xD800 &&
                    s.code_unit_at(i - 1).to_int() <= 0xDBFF {
                    out.write_char(
                      s.code_unit_at(i - 1).to_int().unsafe_to_char(),
                    )
                    out.write_char(u.unsafe_to_char())
                    i -= 2
                  } else {
                    out.write_char(u.unsafe_to_char())
                    i -= 1
                  }
                }
                out.to_string()
              }
            },
          )
        None => Null
      }
    "LTRIM" | "RTRIM" | "TRIM" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(s) else { return Some(Null) }
      let set = if v.length() > 1 { str(1) } else { None }
      let coll = collation_of(e.ty)
      let ansi = !e.ty.is_unicode()
      String(trim_text(s, set, name != "RTRIM", name != "LTRIM", coll, ansi))
    }
    "LEFT" | "RIGHT" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(s) else { return Some(Null) }
      let n = int_of(v[1]).unwrap_or(0L)
      if n < 0L {
        // captured at run time: LEFT shares SUBSTRING's 537 state 2, RIGHT
        // is 536 state 4 (constant lengths fail at bind time, state 6)
        raise if name == "LEFT" {
          substring_length_error()
        } else {
          @types.sql_error(
            536,
            "Invalid length parameter passed to the RIGHT function.",
            state=4,
          )
        }
      }
      // `_SC` collations count a surrogate pair as one character
      // (captured: settings/utf8, RIGHT(N'…😀', 1) is '😀')
      if collation_of(args[0].ty).supplementary() {
        let cs = text_chars(s, true)
        let k = @cmp.minimum(n, cs.length().to_int64()).to_int()
        return Some(
          String(
            if name == "LEFT" {
              cs[:k].iter().fold(init="", (a, b) => a + b)
            } else {
              cs[cs.length() - k:].iter().fold(init="", (a, b) => a + b)
            },
          ),
        )
      }
      let k = @cmp.minimum(n, s.length().to_int64()).to_int()
      String(
        if name == "LEFT" {
          s.unsafe_substring(start=0, end=k)
        } else {
          s.unsafe_substring(start=s.length() - k, end=s.length())
        },
      )
    }
    "SUBSTRING" => {
      if any_null {
        return Some(Null)
      }
      let start = int_of(v[1]).unwrap_or(1L)
      let len = if v.length() == 2 { 0L } else { int_of(v[2]).unwrap_or(0L) }
      if len < 0L {
        raise substring_length_error()
      }
      let slice = (total : Int) => {
        let from = @cmp.maximum(start, 1L)
        let to = if v.length() == 2 {
          total.to_int64() + 1L
        } else {
          @cmp.minimum(start + len, total.to_int64() + 1L)
        }
        if to <= from {
          (0, 0)
        } else {
          ((from - 1L).to_int(), (to - 1L).to_int())
        }
      }
      match v[0] {
        Binary(b) if args[0].ty.family() == FBinary => {
          let (a, z) = slice(b.length())
          Binary(b[a:z].to_owned())
        }
        _ => {
          guard str(0) is Some(s) else { return Some(Null) }
          if collation_of(args[0].ty).supplementary() {
            let cs = text_chars(s, true)
            let (a, z) = slice(cs.length())
            return Some(String(cs[a:z].iter().fold(init="", (x, y) => x + y)))
          }
          let (a, z) = slice(s.length())
          String(s.unsafe_substring(start=a, end=z))
        }
      }
    }
    "REPLACE" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(s) && str(1) is Some(find) && str(2) is Some(rep) else {
        return Some(Null)
      }
      if find.length() == 0 {
        return Some(String(s))
      }
      let coll = collation_of(e.ty)
      let ansi = !e.ty.is_unicode()
      let out = StringBuilder()
      let mut i = 0
      while i < s.length() {
        guard coll_find(s, find, i + 1, coll, ansi) is Some((pos, len)) else {
          out.write_string(s.unsafe_substring(start=i, end=s.length()))
          break
        }
        out.write_string(s.unsafe_substring(start=i, end=pos - 1))
        out.write_string(rep)
        i = pos - 1 + len
      }
      String(cap_text(out.to_string(), e.ty))
    }
    "REPLICATE" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(s) else { return Some(Null) }
      let n = int_of(v[1]).unwrap_or(0L)
      if n < 0L {
        return Some(Null)
      }
      let cap = match e.ty {
        VarChar(Some(_), _) => 8000L
        NVarChar(Some(_), _) => 4000L
        _ => 2147483647L
      }
      // a non-max result keeps whole copies only (captured:
      // DATALENGTH(REPLICATE('abc', 2667)) is 7998)
      let copies = if s.length() == 0 {
        0L
      } else {
        @cmp.minimum(n, cap / s.length().to_int64())
      }
      String(s.repeat(copies.to_int()))
    }
    "SPACE" => {
      if any_null {
        return Some(Null)
      }
      let n = int_of(v[0]).unwrap_or(0L)
      if n < 0L {
        Null
      } else {
        String(" ".repeat(@cmp.minimum(n, 8000L).to_int()))
      }
    }
    "CHARINDEX" => {
      if any_null {
        return Some(Null)
      }
      // a bigint start beyond int is clamped (captured: 3000000000 gives 0,
      // -3000000000 searches from 1)
      // (only for a max search string; otherwise 8115 like any int argument)
      let start = match v.get(2) {
        Some(BigInt(n)) if e.ty is BigInt => n
        Some(x) => int_of(x).unwrap_or(1L)
        None => 1L
      }
      guard str(0) is Some(n) && str(1) is Some(h) else { return Some(Null) }
      let coll = pair_collation(args[0].ty, args[1].ty)
      let from = @cmp.maximum(1L, @cmp.minimum(start, 2147483647L)).to_int()
      // `_SC` collations count a surrogate pair as one character (captured:
      // CHARINDEX(N'b', 😀b COLLATE …_SC) is 2)
      let sc = coll.supplementary()
      let pair_at = (k : Int) => {
        k + 1 < h.length() &&
        h[k].to_int() >= 0xD800 &&
        h[k].to_int() <= 0xDBFF &&
        h[k + 1].to_int() >= 0xDC00 &&
        h[k + 1].to_int() <= 0xDFFF
      }
      let unit_from = if sc {
        let mut k = 0
        let mut c = 1
        while c < from && k < h.length() {
          k += if pair_at(k) { 2 } else { 1 }
          c += 1
        }
        if c < from {
          h.length() + 1
        } else {
          k + 1
        }
      } else {
        from
      }
      let pos = match
        coll_find(h, n, unit_from, coll, !args[1].ty.is_unicode()) {
        Some((p, _)) if sc => {
          let mut k = 0
          let mut c = 1
          while k < p - 1 {
            k += if pair_at(k) { 2 } else { 1 }
            c += 1
          }
          c
        }
        Some((p, _)) => p
        None => 0
      }
      int_result(e.ty, pos.to_int64())
    }
    "PATINDEX" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(p) && str(1) is Some(s) else { return Some(Null) }
      let coll = pair_collation(args[0].ty, args[1].ty)
      let ansi = !args[0].ty.is_unicode() && !args[1].ty.is_unicode()
      int_result(e.ty, patindex(p, s, coll, ansi).to_int64())
    }
    "CONCAT" | "CONCAT_WS" => {
      let pieces : Array[String] = []
      if name == "CONCAT" {
        for i in 0..<v.length() {
          match str(i) {
            Some(s) => pieces.push(s)
            None => ()
          }
        }
      } else {
        let sep = str(0).unwrap_or("")
        let mut first = true
        for i in 1..<v.length() {
          match str(i) {
            Some(s) => {
              if !first {
                pieces.push(sep)
              }
              pieces.push(s)
              first = false
            }
            None => ()
          }
        }
      }
      String(cap_pieces(pieces, e.ty))
    }
    "NCHAR" | "CHAR" => char_value(v[0], name == "CHAR")
    "ASCII" | "UNICODE" =>
      match str(0) {
        Some(s) if s.length() > 0 => {
          let c = s.code_unit_at(0).to_int()
          if name == "ASCII" {
            Int(@types.cp1252_byte_of(c))
          } else {
            Int(c)
          }
        }
        _ => Null
      }
    "STUFF" => {
      if v[0] is Null || v[1] is Null || v[2] is Null {
        return Some(Null)
      }
      guard str(0) is Some(s) else { return Some(Null) }
      // captured: a NULL replacement deletes (STUFF('abcdef', 2, 1, NULL))
      let rep = str(3).unwrap_or("")
      let start = int_of(v[1]).unwrap_or(0L)
      let n = int_of(v[2]).unwrap_or(0L)
      if start < 1L || start > s.length().to_int64() || n < 0L {
        return Some(Null)
      }
      let a = (start - 1L).to_int()
      let z = @cmp.minimum(start - 1L + n, s.length().to_int64()).to_int()
      String(
        cap_text(
          s.unsafe_substring(start=0, end=a) +
          rep +
          s.unsafe_substring(start=z, end=s.length()),
          e.ty,
        ),
      )
    }
    "STR" => {
      if any_null {
        return Some(Null)
      }
      let x = match v[0] {
        Float(d) => d
        _ => return Some(Null)
      }
      let len = if v.length() > 1 { int_of(v[1]).unwrap_or(10L) } else { 10L }
      let dec = if v.length() > 2 { int_of(v[2]).unwrap_or(0L) } else { 0L }
      match str_format(x, len, dec) {
        Some(s) => String(s)
        None => Null
      }
    }
    "QUOTENAME" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(s) else { return Some(Null) }
      let q = if v.length() > 1 { str(1).unwrap_or("") } else { "[" }
      match quotename(s, q) {
        Some(r) => String(r)
        None => Null
      }
    }
    "STRING_ESCAPE" => {
      // trailing blanks of the kind are ignored ('json  ', char(8)); a NULL
      // kind is 8116 state 8 (msduck string-escape-format)
      guard str(1) is Some(kind) else {
        raise @types.sql_error(
          8116,
          "Argument data type NULL is invalid for argument 2 of STRING_ESCAPE function.",
          state=8,
        )
      }
      if kind.trim_end(chars=" ").to_owned().to_lower() != "json" {
        raise @types.sql_error(
          13622, "An invalid value was specified for argument 2.",
        )
      }
      match str(0) {
        Some(s) => String(string_escape_json(s))
        None => Null
      }
    }
    "TRANSLATE" => {
      if any_null {
        return Some(Null)
      }
      guard str(0) is Some(s) && str(1) is Some(from) && str(2) is Some(to) else {
        return Some(Null)
      }
      let coll = collation_of(args[0].ty)
      // `_SC` collations count a surrogate pair as one character (captured:
      // TRANSLATE(…, N'x', N'😀') works under …_SC, is 9828 state 3 else)
      let sc = coll.supplementary()
      let (sc_chars, from_chars, to_chars) = (
        text_chars(s, sc),
        text_chars(from, sc),
        text_chars(to, sc),
      )
      if from_chars.length() != to_chars.length() {
        // state 3 when the mapping strings come from variables, parameters
        // or table columns, or a surrogate pair makes the difference; else 1
        // (captured: TRANSLATE('abc','ab','x') and constant CTE columns 1;
        // a table column, parameters, N'x' → N'😀' 3)
        let runtime = match v.get(3) {
          Some(Bit(b)) => b
          _ => false
        }
        let surrogate = (t : String) => t.iter().any(c => c.to_int() >= 0x10000)
        raise @types.sql_error(
          9828,
          "The second and third arguments of the TRANSLATE built-in function must contain an equal number of characters.",
          state=if runtime || surrogate(from) || surrogate(to) { 3 } else { 1 },
        )
      }
      let ansi = !args[0].ty.is_unicode()
      let out = StringBuilder()
      for c in sc_chars {
        let mut done = false
        for j, f in from_chars {
          if units_equal(c, f, coll, ansi) {
            out.write_string(to_chars[j])
            done = true
            break
          }
        }
        if !done {
          out.write_string(c)
        }
      }
      String(cap_text(out.to_string(), e.ty))
    }
    "SOUNDEX" | "SOUNDEX_100" =>
      match str(0) {
        Some(s) =>
          String(
            if name == "SOUNDEX" {
              soundex(s)
            } else {
              soundex_with(s, true, legacy=true)
            },
          )
        None => Null
      }
    "DIFFERENCE" | "DIFFERENCE_100" =>
      match (str(0), str(1)) {
        (Some(a), Some(b)) =>
          Int(difference(a, b, legacy=name == "DIFFERENCE_100"))
        _ => Null
      }
    _ => return None
  }
  Some(r)
}

///|
/// Characters of a string counting a surrogate pair once.
fn code_points(s : String) -> Int {
  let mut n = 0
  for i in 0..<s.length() {
    let u = s.code_unit_at(i).to_int()
    if !(u >= 0xDC00 &&
      u <= 0xDFFF &&
      i > 0 &&
      s.code_unit_at(i - 1).to_int() >= 0xD800 &&
      s.code_unit_at(i - 1).to_int() <= 0xDBFF) {
      n += 1
    }
  }
  n
}

///|
// Only immutable String values escape these private tables. Cache the common
// Unicode range and share its entries wherever the CHAR code page agrees.
let nchar_latin1_values : FixedArray[@types.Value] = FixedArray::makei(256, n => {
  String(n.unsafe_to_char().to_string())
})

///|
let char_values : FixedArray[@types.Value] = FixedArray::makei(256, n => {
  let unit = @types.cp1252_decode(n)
  if unit < 256 {
    nchar_latin1_values[unit]
  } else {
    String(unit.unsafe_to_char().to_string())
  }
})

///|
/// Shared scalar implementation for interpreted and compiled CHAR/NCHAR.
fn char_value(
  v : @types.Value,
  ansi : Bool,
) -> @types.Value raise @types.SqlError {
  let n = int_of(v).unwrap_or(-1L)
  let limit = if ansi { 255L } else { 0xFFFFL }
  if n < 0L || n > limit {
    Null
  } else if ansi {
    char_values[n.to_int()]
  } else if n < 256L {
    nchar_latin1_values[n.to_int()]
  } else {
    String(n.to_int().unsafe_to_char().to_string())
  }
}
