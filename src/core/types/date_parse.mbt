// Character string → date/time parsing as SQL Server does it under
// SET LANGUAGE us_english / SET DATEFORMAT mdy (rules and evidence:
// docs/reference/date-strings.md, captures harness/corpus/datestrings).
//
// SQL Server has two parsers:
//
// - the *legacy* one behind datetime and smalldatetime: tolerant (time
//   anywhere, 3-digit parts, mixed separators), only U+0020 is whitespace,
//   at most 3 fraction digits, and it reports two error classes:
//   syntax (241 / smalldatetime 295) and value (242 "out-of-range");
// - the *new* one behind date, time, datetime2 and datetimeoffset: stricter
//   shapes, tab is whitespace, up to 7 fraction digits (more are rounded),
//   UTC offsets, and every failure is 241.
//
// Both share a tokenizer. CONVERT styles (101, 103, …) select the day/month/
// year order and the year width; see `DateStyle`.

///|
/// Why a string did not parse.
priv suberror DateParseError {
  /// malformed: 241 (smalldatetime 295) for the legacy parser, 241 for the new
  Syntax
  /// well-formed but an invalid or duplicated field: 242 state 3 (legacy only)
  Value
  /// the new parser under a style that accepts no separated numeric date:
  /// 9807 state 0
  StyleMismatch
}

///|
priv enum DateOrder {
  Mdy
  Dmy
  Ymd
} derive(Eq)

///|
/// What a CONVERT style changes when parsing a character string.
priv struct DateStyle {
  /// order of numeric date parts
  order : DateOrder
  /// required year width in separated numeric dates: 0 any, 2 or 4
  year_digits : Int
  /// an explicit style (not 0): the new parser takes the year position from
  /// `order` instead of accepting a leading 4-digit year
  explicit : Bool
  /// separated numeric dates (`1/2/2024`) allowed at all
  numeric : Bool
  /// legacy: only the strict ISO 8601 numeric forms (126, 127)
  iso_only : Bool
  /// legacy: the `yyyy-mm-ddThh:mi:ss` form allowed
  iso_t : Bool
  /// legacy: `Z` allowed
  iso_z : Bool
  /// legacy: month names and 6/8-digit unseparated dates allowed
  words : Bool
  /// styles 130/131: numeric dates are Hijri (dd/mm/yyyy); no month names,
  /// unseparated or ISO `T` dates
  hijri : Bool
}

///|
let default_date_style : DateStyle = {
  order: Mdy,
  year_digits: 0,
  explicit: false,
  numeric: true,
  iso_only: false,
  iso_t: true,
  iso_z: true,
  words: true,
  hijri: false,
}

///|
/// The parsing rules of a CONVERT style for character → date/time, or None
/// when the new parser rejects the style number (9809). Captured behaviour:
/// harness/corpus/datestrings/styles.cases.json (the numeric styles) and
/// harness/corpus/conversion/input-styles.cases.json (the rest).
///
/// - The text styles (6-9, 12-14, 24, 100, 106-109, 113, 114) accept no
///   separated numeric date, like 112. 22 is mm/dd/yy and 23/25 yyyy-mm-dd
///   for the new parser, but like 112 for the legacy one.
/// - 130/131 read dd/mm/yyyy as a Hijri date (legacy: both; new parser:
///   131 only, 130 accepts no numeric date).
/// - Any other number: the new parser raises 9809, the legacy one behaves
///   like 112.
fn date_style(style : Int, legacy : Bool) -> DateStyle? {
  let numeric = (order : DateOrder, digits : Int) => {
    Some({
      ..default_date_style,
      order,
      year_digits: digits,
      explicit: true,
      iso_t: false,
      iso_z: false,
    })
  }
  let text_only : DateStyle = {
    ..default_date_style,
    explicit: true,
    numeric: false,
    iso_t: false,
    iso_z: false,
  }
  let hijri : DateStyle = {
    ..default_date_style,
    order: Dmy,
    year_digits: 4,
    explicit: true,
    iso_t: false,
    iso_z: false,
    words: false,
    hijri: true,
  }
  match style {
    0 => Some(default_date_style)
    1 | 10 => numeric(Mdy, 2)
    2 | 11 => numeric(Ymd, 2)
    3 | 4 | 5 => numeric(Dmy, 2)
    101 | 110 => numeric(Mdy, 4)
    102 | 111 | 20 | 21 | 120 | 121 => numeric(Ymd, 4)
    103 | 104 | 105 => numeric(Dmy, 4)
    22 if !legacy => numeric(Mdy, 2)
    23 | 25 if !legacy => numeric(Ymd, 4)
    112
    | 6
    | 7
    | 8
    | 9
    | 12
    | 13
    | 14
    | 22
    | 23
    | 24
    | 25
    | 100
    | 106
    | 107
    | 108
    | 109
    | 113
    | 114 => Some(text_only)
    126 =>
      Some({
        ..default_date_style,
        order: Ymd,
        year_digits: 4,
        explicit: true,
        iso_only: true,
        iso_z: false,
      })
    127 =>
      Some({
        ..default_date_style,
        order: Ymd,
        year_digits: 4,
        explicit: true,
        iso_only: true,
        words: false,
      })
    131 => Some(hijri)
    130 => Some(if legacy { hijri } else { { ..hijri, numeric: false, } })
    _ => if legacy { Some(text_only) } else { None }
  }
}

// ------------------------------------------------------------------ tokens

///|
priv enum TokKind {
  Num
  Month
  Am
  Pm
  TLetter
  ZLetter
  Sep(UInt16)
} derive(Eq)

///|
priv struct Tok {
  kind : TokKind
  /// first code unit in the source
  start : Int
  /// digit count (Num)
  len : Int
  /// numeric value (Num, -1 when longer than 9 digits) or month (Month)
  value : Int
  /// whitespace precedes this token
  sp : Bool
}

///|
let month_words : Array[(String, String)] = [
  ("JAN", "JANUARY"),
  ("FEB", "FEBRUARY"),
  ("MAR", "MARCH"),
  ("APR", "APRIL"),
  ("MAY", "MAY"),
  ("JUN", "JUNE"),
  ("JUL", "JULY"),
  ("AUG", "AUGUST"),
  ("SEP", "SEPTEMBER"),
  ("OCT", "OCTOBER"),
  ("NOV", "NOVEMBER"),
  ("DEC", "DECEMBER"),
]

///|
fn is_letter(c : UInt16) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

///|
/// Split into tokens. Whitespace is U+0020 (plus TAB for the new parser);
/// any other character, or a word that is not a month name, AM, PM, `T` or
/// `Z`, is a syntax error. `+` exists only for the new parser's offsets.
fn tokenize(s : String, legacy : Bool) -> Array[Tok] raise DateParseError {
  let n = s.length()
  let out : Array[Tok] = []
  let mut i = 0
  let mut sp = false
  while i < n {
    let c = s[i]
    if c == ' ' || (c == '\t' && !legacy) {
      sp = true
      i += 1
    } else if is_digit(c) {
      let start = i
      while i < n && is_digit(s[i]) {
        i += 1
      }
      let len = i - start
      let mut value = 0
      if len <= 9 {
        for k in start..<i {
          value = value * 10 + (s[k].to_int() - '0'.to_int())
        }
      } else {
        value = -1
      }
      out.push({ kind: Num, start, len, value, sp, })
      sp = false
    } else if is_letter(c) {
      let start = i
      while i < n && is_letter(s[i]) {
        i += 1
      }
      let w = s.unsafe_substring(start~, end=i)
      let kind : TokKind = if w == "T" {
        TLetter
      } else if w == "Z" {
        ZLetter
      } else {
        let u = w.to_upper()
        if u == "AM" {
          Am
        } else if u == "PM" {
          Pm
        } else {
          Month
        }
      }
      let mut value = 0
      if kind == Month {
        let u = w.to_upper()
        for k, names in month_words {
          if u == names.0 || u == names.1 {
            value = k + 1
          }
        }
        if value == 0 {
          raise Syntax
        }
      }
      out.push({ kind, start, len: i - start, value, sp, })
      sp = false
    } else if c == '/' ||
      c == '-' ||
      c == '.' ||
      c == ':' ||
      c == ',' ||
      (c == '+' && !legacy) {
      out.push({ kind: Sep(c), start: i, len: 1, value: 0, sp, })
      sp = false
      i += 1
    } else {
      raise Syntax
    }
  }
  out
}

///|
fn is_date_sep(t : Tok) -> Bool {
  t.kind is Sep(c) && (c == '/' || c == '-' || c == '.')
}

///|
/// A two-digit year under the default two digit year cutoff (2049).
fn window_year(v : Int) -> Int {
  if v < 50 {
    2000 + v
  } else {
    1900 + v
  }
}

///|
/// Fraction digits starting at `start` (`len` of them) as 100 ns ticks,
/// rounded half up at the 8th digit (captured: `.12345678` → `.1234568`).
fn fraction_ticks(s : String, start : Int, len : Int) -> Int64 {
  let mut v = 0L
  for k in 0..<7 {
    v = v * 10L +
      (if k < len {
        (s[start + k].to_int() - '0'.to_int()).to_int64()
      } else {
        0L
      })
  }
  if len > 7 && s[start + 7] >= '5' {
    v += 1L
  }
  v
}

///|
/// Hour adjusted for AM/PM (`ampm`: 0 none, 1 AM, 2 PM). Captured: `12 AM`
/// is 0, `13 PM` stays 13, `0 PM` and `13 AM` fail.
fn ampm_hour(h : Int, ampm : Int) -> Int? {
  match ampm {
    1 => if h > 12 { None } else if h == 12 { Some(0) } else { Some(h) }
    2 => if h == 0 { None } else if h < 12 { Some(h + 12) } else { Some(h) }
    _ => Some(h)
  }
}

///|
fn time_ticks(
  h : Int,
  m : Int,
  sec : Int,
  frac : Int64,
  ampm : Int,
) -> Int64 raise DateParseError {
  let hour = match ampm_hour(h, ampm) {
    Some(x) => x
    None => raise Value
  }
  if hour > 23 || m > 59 || sec > 59 {
    raise Value
  }
  hour.to_int64() * 3600L * TICKS_PER_SECOND +
  m.to_int64() * TICKS_PER_MINUTE +
  sec.to_int64() * TICKS_PER_SECOND +
  frac
}

///|
fn check_date(
  st : DateStyle,
  y : Int,
  m : Int,
  d : Int,
) -> (Int, Int, Int) raise DateParseError {
  // Hijri styles: a Hijri date, converted by the caller (captured:
  // 29/02/1445 is valid under 131 although 1445 is no Gregorian leap year)
  if !(if st.hijri { hijri_valid(y, m, d) } else { is_valid_date(y, m, d) }) {
    raise Value
  }
  (y, m, d)
}

///|
/// The date from a 4-, 6- or 8-digit unseparated number.
fn unseparated_date(t : Tok) -> (Int, Int, Int)? {
  let v = t.value
  match t.len {
    4 => Some((v, 1, 1))
    6 => Some((window_year(v / 10000), v / 100 % 100, v % 100))
    8 => Some((v / 10000, v / 100 % 100, v % 100))
    _ => None
  }
}

// ------------------------------------------------------------- new parser

///|
/// Parser of date, time, datetime2 and datetimeoffset.
priv struct NewParser {
  s : String
  toks : Array[Tok]
  style : DateStyle
  mut i : Int
}

///|
fn NewParser::peek(self : NewParser, k : Int) -> Tok? {
  self.toks.get(self.i + k)
}

///|
fn NewParser::at_kind(self : NewParser, k : Int, kind : TokKind) -> Bool {
  match self.peek(k) {
    Some(t) => t.kind == kind
    None => false
  }
}

///|
/// Next token must be a number of `lo..=hi` digits.
fn NewParser::num(
  self : NewParser,
  lo : Int,
  hi : Int,
  tight : Bool,
) -> Int raise DateParseError {
  match self.peek(0) {
    Some({ kind: Num, len, value, sp, .. }) if len >= lo &&
      len <= hi &&
      !(tight && sp) => {
      self.i += 1
      value
    }
    _ => raise Syntax
  }
}

///|
fn NewParser::expect_sep(
  self : NewParser,
  c : UInt16,
  tight : Bool,
) -> Unit raise DateParseError {
  match self.peek(0) {
    Some({ kind: Sep(x), sp, .. }) if x == c && !(tight && sp) => self.i += 1
    _ => raise Syntax
  }
}

///|
/// Does a time start at the current token (`h:` or `h AM`)?
fn NewParser::time_starts(self : NewParser) -> Bool {
  self.at_kind(0, Num) &&
  (
    (self.at_kind(1, Sep(':')) && !self.toks[self.i + 1].sp) ||
    self.at_kind(1, Am) ||
    self.at_kind(1, Pm)
  )
}

///|
/// `h:mi[:ss[.fffffff|:mmm]][ AM|PM]` or `h AM|PM` → ticks.
fn NewParser::time(self : NewParser) -> Int64 raise DateParseError {
  let h = self.num(1, 2, false)
  let mut m = 0
  let mut sec = 0
  let mut frac = 0L
  if self.at_kind(0, Sep(':')) {
    self.i += 1
    m = self.num(1, 2, true)
    if self.at_kind(0, Sep(':')) && !self.toks[self.i].sp {
      self.i += 1
      sec = self.num(1, 2, true)
      match (self.peek(0), self.peek(1)) {
        (Some({ kind: Sep('.'), sp: false, .. }), Some(f)) if f.kind == Num &&
          !f.sp => {
          frac = fraction_ticks(self.s, f.start, f.len)
          self.i += 2
        }
        (Some({ kind: Sep(':'), sp: false, .. }), Some(f)) if f.kind == Num &&
          !f.sp &&
          f.len <= 3 => {
          frac = f.value.to_int64() * 10000L
          self.i += 2
        }
        (Some({ kind: Sep('.' | ':'), sp: false, .. }), _) => raise Syntax
        _ => ()
      }
    }
  }
  let ampm = match self.peek(0) {
    Some({ kind: Am, .. }) => 1
    Some({ kind: Pm, .. }) => 2
    _ => 0
  }
  if ampm != 0 {
    self.i += 1
  }
  // `23:59:59.99999999` may round to 24:00 (captured: datetime2 carries
  // into the next day, time keeps 23:59:59.9999999, date ignores it)
  time_ticks(h, m, sec, frac, ampm) catch {
    _ => raise Syntax
  }
}

///|
/// `Z`, or `+hh:mi` / `-hh:mi` (1-2 digit fields, at most 14:00).
fn NewParser::offset(
  self : NewParser,
  tight : Bool,
) -> Int? raise DateParseError {
  match self.peek(0) {
    Some({ kind: ZLetter, sp, .. }) => {
      if tight && sp {
        raise Syntax
      }
      self.i += 1
      Some(0)
    }
    Some({ kind: Sep('+' | '-') as k, sp, .. }) => {
      if tight && sp {
        raise Syntax
      }
      self.i += 1
      let oh = self.num(1, 2, tight)
      self.expect_sep(':', true)
      let om = self.num(1, 2, true)
      let total = oh * 60 + om
      if om > 59 || total > 840 {
        raise Syntax
      }
      Some(if k == Sep('-') { -total } else { total })
    }
    _ => None
  }
}

///|
/// A year field of a numeric or alphabetic date: 1-2 digits are windowed,
/// 4 are literal; 3 or 5+ digits fail.
fn new_year(t : Tok) -> Int raise DateParseError {
  match t.len {
    1 | 2 => window_year(t.value)
    4 => t.value
    _ => raise Syntax
  }
}

///|
fn new_day_or_month(t : Tok) -> Int raise DateParseError {
  if t.len > 2 {
    raise Syntax
  }
  t.value
}

///|
/// `yyyy-mm-ddThh:mi:ss[.fffffff][Z|±hh:mi]`, no spaces inside.
fn NewParser::iso_t(self : NewParser) -> ParsedTemporal raise DateParseError {
  let y = self.num(4, 4, false)
  self.expect_sep('-', true)
  let m = self.num(1, 2, true)
  self.expect_sep('-', true)
  let d = self.num(1, 2, true)
  match self.peek(0) {
    Some({ kind: TLetter, sp: false, .. }) => self.i += 1
    _ => raise Syntax
  }
  let h = self.num(2, 2, true)
  self.expect_sep(':', true)
  let mi = self.num(1, 2, true)
  self.expect_sep(':', true)
  let sec = self.num(1, 2, true)
  let mut frac = 0L
  let mut digits = 0
  if self.at_kind(0, Sep('.')) && !self.toks[self.i].sp {
    match self.peek(1) {
      Some({ kind: Num, sp: false, start, len, .. }) => {
        frac = fraction_ticks(self.s, start, len)
        digits = len
        self.i += 2
      }
      _ => raise Syntax
    }
  }
  let offset = self.offset(true)
  if self.i != self.toks.length() {
    raise Syntax
  }
  let date = check_date(self.style, y, m, d) catch { _ => raise Syntax }
  let time = time_ticks(h, mi, sec, frac, 0) catch { _ => raise Syntax }
  { date: Some(date), time: Some(time), fraction_digits: digits, offset, }
}

///|
/// Numeric `a<sep>b<sep>c` with the separator already known equal.
fn NewParser::numeric_date(
  self : NewParser,
  a : Tok,
  b : Tok,
  c : Tok,
) -> (Int, Int, Int) raise DateParseError {
  let st = self.style
  if !st.numeric {
    raise StyleMismatch
  }
  let year_ok = (t : Tok) => {
    match st.year_digits {
      2 => t.len <= 2
      4 => t.len == 4
      _ => true
    }
  }
  let ymd = if st.explicit { st.order == Ymd } else { a.len == 4 }
  if ymd {
    if a.len != 4 && !(st.year_digits == 2 && a.len <= 2) {
      raise Syntax
    }
    if !year_ok(a) {
      raise Syntax
    }
    (new_year(a), new_day_or_month(b), new_day_or_month(c))
  } else {
    if !year_ok(c) {
      raise Syntax
    }
    let y = new_year(c)
    if st.order == Dmy {
      (y, new_day_or_month(b), new_day_or_month(a))
    } else {
      (y, new_day_or_month(a), new_day_or_month(b))
    }
  }
}

///|
/// Day and year from an alphabetic date's numbers: a 4-digit number is the
/// year, otherwise the first is the day and the second the year.
fn alpha_day_year(nums : Array[Tok]) -> (Int, Int) raise DateParseError {
  match nums {
    [y] if y.len == 4 => (1, y.value)
    [a, b] if a.len == 4 && b.len != 4 => (new_day_or_month(b), a.value)
    [a, b] if b.len == 4 && a.len != 4 => (new_day_or_month(a), b.value)
    [a, b] if a.len != 4 && b.len != 4 => (new_day_or_month(a), new_year(b))
    _ => raise Syntax
  }
}

///|
/// The date part, leaving `i` after it. Returns the date and whether it was
/// an ISO `yyyy-mm-dd` (which alone may carry a `Z`).
fn NewParser::date(
  self : NewParser,
) -> ((Int, Int, Int), Bool) raise DateParseError {
  let first = self.toks[self.i]
  // separated: a <sep> b <sep> c, where b may be a month name
  match (self.peek(1), self.peek(2), self.peek(3), self.peek(4)) {
    (Some(s1), Some(b), Some(s2), Some(c)) if first.kind == Num &&
      is_date_sep(s1) => {
      if !(s2.kind == s1.kind) || c.kind != Num {
        raise Syntax
      }
      self.i += 5
      if b.kind == Month {
        if self.style.hijri {
          raise Syntax
        }
        // 2-Jan-2024, 2024/Jan/02
        let (d, y) = if first.len == 4 {
          (new_day_or_month(c), first.value)
        } else {
          (new_day_or_month(first), new_year(c))
        }
        return (check_date(self.style, y, b.value, d), false)
      }
      if b.kind != Num {
        raise Syntax
      }
      let iso = s1.kind == Sep('-') && first.len == 4 && !s1.sp && !s2.sp
      let zulu = iso &&
        (match self.peek(0) {
          Some({ kind: ZLetter, sp: false, .. }) => true
          _ => false
        })
      // `yyyy-mm-ddZ` is ISO 8601 under every style (captured)
      let date = if zulu {
        (first.value, new_day_or_month(b), new_day_or_month(c))
      } else {
        self.numeric_date(first, b, c)
      }
      return (check_date(self.style, date.0, date.1, date.2), iso)
    }
    (Some(s1), _, _, _) if first.kind == Num && is_date_sep(s1) => raise Syntax
    _ => ()
  }
  // Hijri styles take only dd/mm/yyyy (captured: month names and
  // unseparated dates fail under 131)
  if self.style.hijri {
    raise Syntax
  }
  // alphabetic: up to three components with exactly one month name
  let nums : Array[Tok] = []
  let mut month = 0
  let mut count = 0
  let mut comma_before_last = false
  while count < 3 && self.i < self.toks.length() {
    if count > 0 && self.time_starts() {
      break
    }
    let t = self.toks[self.i]
    if t.kind == Sep(',') {
      // only right before the third component, which must be the year
      if count != 2 || comma_before_last {
        raise Syntax
      }
      comma_before_last = true
      self.i += 1
      continue
    }
    if count > 0 && !t.sp && !comma_before_last {
      raise Syntax
    }
    match t.kind {
      Num => nums.push(t)
      Month => {
        if month != 0 {
          raise Syntax
        }
        month = t.value
      }
      _ => raise Syntax
    }
    count += 1
    self.i += 1
  }
  if comma_before_last && (count != 3 || self.toks[self.i - 1].kind != Num) {
    raise Syntax
  }
  if month == 0 {
    // unseparated yyyy, yymmdd, yyyymmdd
    match nums {
      [t] =>
        match unseparated_date(t) {
          Some((y, m, d)) => return (check_date(self.style, y, m, d), false)
          None => raise Syntax
        }
      _ => raise Syntax
    }
  }
  if comma_before_last {
    // the comma must precede the year: `Jan 2024, 2` fails
    match nums {
      [a, _] if a.len == 4 => raise Syntax
      _ => ()
    }
  }
  let (d, y) = alpha_day_year(nums)
  (check_date(self.style, y, month, d), false)
}

///|
fn NewParser::parse(self : NewParser) -> ParsedTemporal raise DateParseError {
  let n = self.toks.length()
  if n == 0 {
    return { date: None, time: None, fraction_digits: 0, offset: None, }
  }
  if self.toks.iter().any(t => t.kind == TLetter) {
    if self.style.hijri {
      raise Syntax
    }
    return self.iso_t() catch {
      // a numeric date before a misplaced T under a style without numeric
      // dates (captured: `1/2/2024T10:11`, style 112 → 9807)
      Syntax if !self.style.numeric &&
        n > 1 &&
        self.toks[0].kind == Num &&
        is_date_sep(self.toks[1]) => raise StyleMismatch
      e => raise e
    }
  }
  // `Z` after a space needs a time before it (`2024-01-02 Z` fails)
  for k, t in self.toks {
    if t.kind == ZLetter &&
      t.sp &&
      !self.toks[:k].iter().any(u => u.kind is (Sep(':') | Am | Pm)) {
      raise Syntax
    }
  }
  let mut date : (Int, Int, Int)? = None
  let mut time : Int64? = None
  let mut offset : Int? = None
  if !self.time_starts() {
    let (d, iso) = self.date()
    date = Some(d)
    if iso && self.at_kind(0, ZLetter) && !self.toks[self.i].sp {
      self.i += 1
      offset = Some(0)
    }
  }
  if offset is None && self.i < n {
    if date is Some(_) && !self.toks[self.i].sp {
      raise Syntax
    }
    if !self.time_starts() {
      raise Syntax
    }
    time = Some(self.time())
    offset = self.offset(false)
  }
  if self.i != n {
    raise Syntax
  }
  { date, time, fraction_digits: 0, offset, }
}

// ---------------------------------------------------------- legacy parser

///|
/// Parser of datetime and smalldatetime.
priv struct LegacyParser {
  s : String
  toks : Array[Tok]
  style : DateStyle
}

///|
/// The legacy year: 1-2 digits windowed, 3 digits windowed below 100 (`024`
/// is 2024, `123` is year 123 and out of range), 4 literal, 5+ a syntax
/// error.
fn legacy_year(t : Tok) -> Int raise DateParseError {
  match t.len {
    1 | 2 => window_year(t.value)
    3 => if t.value < 100 { window_year(t.value) } else { t.value }
    4 => t.value
    _ => raise Syntax
  }
}

///|
/// A time group starting at `toks[i]` (a number followed by `:`), returning
/// the ticks and the index after it (including an AM/PM).
fn LegacyParser::time_group(
  self : LegacyParser,
  i : Int,
) -> (Int64, Int) raise DateParseError {
  let toks = self.toks
  let n = toks.length()
  let num = (k : Int) => {
    if k < n && toks[k].kind == Num {
      Some(toks[k])
    } else {
      None
    }
  }
  let sep = (k : Int, c : UInt16) => k < n && toks[k].kind == Sep(c)
  let field = (k : Int) => {
    match num(k) {
      Some(t) if t.len <= 3 => t.value
      _ => raise Syntax
    }
  }
  let h = field(i)
  let m = field(i + 2)
  let mut j = i + 3
  let mut sec = 0
  let mut frac = 0L
  if sep(j, ':') {
    sec = field(j + 1)
    j += 2
    if sep(j, '.') || sep(j, ':') {
      let colon = sep(j, ':')
      match num(j + 1) {
        Some(f) if f.len <= 3 => {
          frac = if colon {
            f.value.to_int64() * 10000L
          } else {
            fraction_ticks(self.s, f.start, f.len)
          }
          j += 2
        }
        _ => raise Syntax
      }
    }
  } else if sep(j, '.') {
    // `10:11.5` is 10:11:00.5
    match num(j + 1) {
      Some(f) if f.len <= 3 => {
        frac = fraction_ticks(self.s, f.start, f.len)
        j += 2
      }
      _ => raise Syntax
    }
  }
  if sep(j, ':') || sep(j, '.') {
    raise Syntax
  }
  let mut ampm = 0
  if j < n && toks[j].kind == Am {
    ampm = 1
    j += 1
  } else if j < n && toks[j].kind == Pm {
    ampm = 2
    j += 1
  }
  (time_ticks(h, m, sec, frac, ampm), j)
}

///|
/// The strict ISO 8601 forms, the only ones where the legacy parser knows
/// `T` and `Z`: `yyyy-mm-dd[Thh:mi:ss[.fff]][ Z][ AM|PM]`, `yyyy[ Z]` and a
/// time followed by `Z`. None when the tokens are not of that shape.
fn LegacyParser::iso(
  self : LegacyParser,
) -> ParsedTemporal? raise DateParseError {
  let toks = self.toks
  let n = toks.length()
  let st = self.style
  let num = (k : Int, len : Int) => {
    k < n && toks[k].kind == Num && toks[k].len == len && !toks[k].sp
  }
  let sep = (k : Int, c : UInt16) => {
    k < n && toks[k].kind == Sep(c) && !toks[k].sp
  }
  let mut date : (Int, Int, Int)? = None
  let mut time : Int64? = None
  let mut j = 0
  if num(0, 4) && sep(1, '-') && num(2, 2) && sep(3, '-') && num(4, 2) {
    date = Some((toks[0].value, toks[2].value, toks[4].value))
    j = 5
    if j < n && toks[j].kind == TLetter && !toks[j].sp {
      if !(num(6, 2) && sep(7, ':') && num(8, 2) && sep(9, ':') && num(10, 2)) {
        raise Syntax
      }
      if !st.iso_t {
        // a Z the style rejects is reported first (captured, style 101)
        if !st.iso_z && toks.iter().any(t => t.kind == ZLetter) {
          raise Syntax
        }
        raise if st.numeric && st.year_digits != 2 { Value } else { Syntax }
      }
      let mut frac = 0L
      j = 11
      if sep(j, '.') {
        if !(j + 1 < n && toks[j + 1].kind == Num && toks[j + 1].len <= 3) {
          raise Syntax
        }
        frac = fraction_ticks(self.s, toks[j + 1].start, toks[j + 1].len)
        j += 2
      }
      let mut ampm = 0
      let mut z = false
      while j < n {
        match toks[j].kind {
          ZLetter if !z && ampm == 0 => z = true
          Am if ampm == 0 => ampm = 1
          Pm if ampm == 0 => ampm = 2
          _ => raise Syntax
        }
        j += 1
      }
      if z && !st.iso_z {
        raise Syntax
      }
      time = Some(
        time_ticks(toks[6].value, toks[8].value, toks[10].value, frac, ampm),
      )
      return Some({ date, time, fraction_digits: 0, offset: None, })
    }
  } else if num(0, 4) && toks.length() == 2 {
    // `2024Z`
    date = Some((toks[0].value, 1, 1))
    j = 1
  } else if n >= 2 && toks[0].kind == Num && toks[1].kind == Sep(':') {
    let (t, k) = self.time_group(0)
    time = Some(t)
    j = k
  } else {
    return None
  }
  // the rest must be a single Z (or nothing for a plain ISO date)
  if j == n {
    return if date is Some(_) && time is None && j == 5 && st.iso_only {
      Some({ date, time, fraction_digits: 0, offset: None, })
    } else {
      None
    }
  }
  if !(j == n - 1 && toks[j].kind == ZLetter) {
    return None
  }
  if !st.iso_z {
    raise Syntax
  }
  Some({ date, time, fraction_digits: 0, offset: None, })
}

///|
fn LegacyParser::parse(
  self : LegacyParser,
) -> ParsedTemporal raise DateParseError {
  let toks = self.toks
  let n = toks.length()
  let st = self.style
  if n == 0 {
    return { date: None, time: None, fraction_digits: 0, offset: None, }
  }
  let has_tz = toks.iter().any(t => t.kind is (TLetter | ZLetter))
  if has_tz || st.iso_only {
    match self.iso() {
      Some(p) => return p
      None => ()
    }
    if has_tz {
      // captured: a leading `T`/`Z` (or `yyyyT…`) is a value error, any
      // other misplaced T or Z a syntax error
      let lead = toks[0].kind is (TLetter | ZLetter) ||
        (
          toks[0].kind == Num &&
          toks[0].len == 4 &&
          toks[1].kind is (TLetter | ZLetter)
        )
      let styled = !st.iso_t &&
        st.numeric &&
        st.year_digits == 4 &&
        toks.iter().any(t => t.kind == TLetter)
      raise if lead || styled { Value } else { Syntax }
    }
  }
  // 1. pull the time out (it may stand anywhere)
  let rest : Array[Tok] = []
  let mut time : Int64? = None
  let mut i = 0
  while i < n {
    let t = toks[i]
    let next = toks.get(i + 1)
    if t.kind == Num && next is Some({ kind: Sep(':'), .. }) {
      let (ticks, j) = self.time_group(i)
      if time is Some(_) {
        raise Value
      }
      time = Some(ticks)
      i = j
    } else if t.kind == Num &&
      next is Some({ kind: Am | Pm, .. }) &&
      !(i > 0 && is_date_sep(toks[i - 1])) {
      // `10 PM`; the year of `1/2/2024 AM` is no hour (the AM then fails)
      if t.len > 2 {
        raise Syntax
      }
      let ampm = if next is Some({ kind: Am, .. }) { 1 } else { 2 }
      if time is Some(_) {
        raise Value
      }
      time = Some(time_ticks(t.value, 0, 0, 0L, ampm))
      i += 2
    } else if t.kind is (Am | Pm) {
      raise Value
    } else {
      rest.push(t)
      i += 1
    }
  }
  // 2. the date from what is left
  let date = self.date(rest)
  { date, time, fraction_digits: 0, offset: None, }
}

///|
fn LegacyParser::date(
  self : LegacyParser,
  rest : Array[Tok],
) -> (Int, Int, Int)? raise DateParseError {
  let st = self.style
  let n = rest.length()
  if n == 0 {
    return None
  }
  // a lone short number is a syntax error even next to a comma
  // (`10:11:12,123`)
  let core = rest.filter(t => t.kind != Sep(','))
  if core is [t] && t.kind == Num && !(t.len is (4 | 6 | 8)) {
    raise Syntax
  }
  match rest[0].kind {
    Sep(',') => raise Value
    Sep(_) => raise Syntax
    _ => ()
  }
  for t in rest {
    if t.kind == Num && t.len > 4 && !(n == 1 && (t.len == 6 || t.len == 8)) {
      raise Syntax
    }
    if t.kind == Sep(':') {
      raise Syntax
    }
  }
  let months = rest.filter(t => t.kind == Month)
  if months.length() > 1 {
    raise Value
  }
  if months.length() == 1 {
    if !st.words {
      raise Syntax
    }
    return Some(self.alpha_date(rest, months[0].value))
  }
  // numeric: a single number, or a separated group
  if n == 1 {
    let t = rest[0]
    if t.len == 4 {
      return Some(check_date(self.style, t.value, 1, 1))
    }
    if !st.words {
      raise Syntax
    }
    match unseparated_date(t) {
      Some((y, m, d)) => return Some(check_date(self.style, y, m, d))
      None => raise Syntax
    }
  }
  if !is_date_sep(rest[1]) {
    // numbers separated only by spaces: two years is a value error
    if rest.iter().all(t => t.kind == Num) {
      let years = rest.filter(t => t.len == 4).length()
      raise if years >= 2 { Value } else { Syntax }
    }
    raise Syntax
  }
  // a <sep> b <sep> c
  let parts : Array[Tok] = [rest[0]]
  let mut k = 1
  while k < n && parts.length() < 3 {
    if !is_date_sep(rest[k]) {
      break
    }
    if k + 1 >= n {
      // trailing separator of an incomplete date
      raise Syntax
    }
    let t = rest[k + 1]
    if t.kind != Num {
      raise Value
    }
    parts.push(t)
    k += 2
  }
  if parts.length() < 3 {
    raise Syntax
  }
  if k < n {
    raise Value
  }
  if !st.numeric || st.iso_only {
    raise Syntax
  }
  Some(self.numeric_date(parts[0], parts[1], parts[2]))
}

///|
fn LegacyParser::numeric_date(
  self : LegacyParser,
  a : Tok,
  b : Tok,
  c : Tok,
) -> (Int, Int, Int) raise DateParseError {
  let st = self.style
  let parts = [a, b, c]
  let fours = parts.filter(t => t.len == 4).length()
  if st.year_digits == 4 && fours == 0 {
    raise Syntax
  }
  if st.year_digits == 2 && fours > 0 {
    raise Syntax
  }
  if fours > 1 {
    raise Value
  }
  // the 4-digit part is the year; the other two keep the style's order
  let mut ypos = parts.search_by(t => t.len == 4).unwrap_or(-1)
  if ypos < 0 {
    ypos = if st.order == Ymd { 0 } else { 2 }
  }
  let others = [0, 1, 2].filter(k => k != ypos).map(k => parts[k])
  let (m, d) = if st.order == Dmy {
    (others[1].value, others[0].value)
  } else {
    (others[0].value, others[1].value)
  }
  check_date(self.style, legacy_year(parts[ypos]), m, d)
}

///|
/// Month name dates: components (numbers and the month) separated by
/// spaces, at most one comma between two of them, or `n-Mon[-n]` with a
/// date separator.
fn LegacyParser::alpha_date(
  self : LegacyParser,
  rest : Array[Tok],
  month : Int,
) -> (Int, Int, Int) raise DateParseError {
  ignore(self)
  let nums : Array[Tok] = []
  let n = rest.length()
  let mut prev : Tok? = None
  // separator kind before the previous component: 0 none/space, 1 comma,
  // 2 date separator
  let mut sep_before_prev = 0
  let mut pending = 0
  for k in 0..<n {
    let t = rest[k]
    match t.kind {
      Sep(',') => {
        match prev {
          None => raise Value
          Some(p) =>
            if pending != 0 || (p.kind == Num && p.len == 4) {
              raise Value
            }
        }
        pending = 1
      }
      Sep(_) => {
        // only `n<sep>Mon` or, after that, `Mon<sep>n`
        match prev {
          Some({ kind: Num, .. }) if pending == 0 &&
            k + 1 < n &&
            rest[k + 1].kind == Month => ()
          Some({ kind: Month, .. }) if pending == 0 && sep_before_prev == 2 =>
            ()
          _ => raise Value
        }
        pending = 2
      }
      Num | Month => {
        if t.kind == Num {
          nums.push(t)
        }
        sep_before_prev = pending
        pending = 0
        prev = Some(t)
      }
      _ => raise Syntax
    }
  }
  if pending != 0 {
    raise Value
  }
  match nums.length() {
    0 => raise Syntax
    1 => {
      let y = nums[0]
      if y.len != 4 {
        raise Syntax
      }
      check_date(self.style, y.value, month, 1)
    }
    2 => {
      let (a, b) = (nums[0], nums[1])
      if a.len == 4 && b.len == 4 {
        raise Value
      }
      let (d, y) = if a.len == 4 {
        (b, a)
      } else if b.len == 4 {
        (a, b)
      } else {
        (a, b)
      }
      check_date(self.style, legacy_year(y), month, d.value)
    }
    _ => raise Value
  }
}

// ----------------------------------------------------------------- entry

///|
/// Which parser and how a failure is reported.
priv enum ParseTarget {
  Legacy
  Modern
}

///|
fn parse_date_string(
  text : String,
  target : ParseTarget,
  style : DateStyle,
) -> ParsedTemporal raise DateParseError {
  match target {
    Legacy => {
      let s = trim_spaces(text)
      let toks = tokenize(s, true)
      { s, toks, style, }.parse()
    }
    Modern => {
      let s = trim_blank(text)
      let toks = tokenize(s, false)
      { s, toks, style, i: 0, }.parse()
    }
  }
}

///|
/// Trim U+0020 and TAB (the new parser's whitespace).
fn trim_blank(s : String) -> String {
  let n = s.length()
  let mut a = 0
  while a < n && (s[a] == ' ' || s[a] == '\t') {
    a += 1
  }
  let mut b = n
  while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') {
    b -= 1
  }
  s.unsafe_substring(start=a, end=b)
}

///|
/// Parse a character string as the date, time, datetime2 and
/// datetimeoffset conversions do under us_english / mdy (style 0).
pub fn parse_temporal(text : String) -> ParsedTemporal raise TemporalParseError {
  parse_date_string(text, Modern, default_date_style) catch {
    _ => raise Invalid
  }
}
