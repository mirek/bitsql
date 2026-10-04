// Date/time text for PARSE / TRY_PARSE (.NET DateTime.Parse in a culture:
// its month and day names and its short-date field order decide numeric
// dates, captured: '01/02/2010' is 1 Feb in en-GB, '02.01.2024' 2 Jan in
// de-DE). Only shapes captured against SQL Server are modelled
// (harness/corpus/analytic/parse-dates.sql); every other shape is reported
// as unsupported so the caller raises an emulator error instead of guessing.

///|
priv enum ParsedDate {
  /// local ticks since 0001-01-01 (rounded to 100 ns) and the explicit
  /// offset in minutes, if the text had one
  ParsedOk(Int64, Int?)
  /// a recognised shape with impossible components (month 13, 24:00, a
  /// weekday that does not match the date): .NET rejects it
  ParsedInvalid
  ParsedUnsupported(String)
  /// the fraction rounded past 9999-12-31 23:59:59.9999999 (.NET AddTicks
  /// throws ArgumentOutOfRangeException)
  ParsedOverflow
}

///|
priv struct DateCursor {
  s : String
  mut i : Int
  cult : CultureData
  /// numeric date field order of the culture's short date pattern:
  /// 0 month-day-year, 1 day-month-year, 2 year-month-day
  order : Int
}

///|
fn date_order(c : CultureData) -> Int {
  let p = c.pat_d
  let y = p.find("y").unwrap_or(0)
  let m = p.find("M").unwrap_or(0)
  let d = p.find("d").unwrap_or(0)
  if y < m && y < d {
    2
  } else if d < m {
    1
  } else {
    0
  }
}

///|
fn DateCursor::at(self : DateCursor) -> Int {
  if self.i < self.s.length() {
    self.s.code_unit_at(self.i).to_int()
  } else {
    -1
  }
}

///|
fn DateCursor::eof(self : DateCursor) -> Bool {
  self.i >= self.s.length()
}

///|
fn DateCursor::skip_ws(self : DateCursor) -> Bool {
  let start = self.i
  while !self.eof() && net_white(self.at()) {
    self.i += 1
  }
  self.i > start
}

///|
fn DateCursor::eat(self : DateCursor, c : Int) -> Bool {
  if self.at() == c {
    self.i += 1
    true
  } else {
    false
  }
}

///|
/// A run of digits: (value, length), None if none. Values are capped to
/// avoid overflow (lengths above 9 never form a valid component).
fn DateCursor::number(self : DateCursor) -> (Int, Int)? {
  let start = self.i
  let mut v = 0
  while !self.eof() && net_digit(self.at()) {
    if self.i - start < 9 {
      v = v * 10 + (self.at() - 0x30)
    }
    self.i += 1
  }
  if self.i == start {
    None
  } else {
    Some((v, self.i - start))
  }
}

///|
fn DateCursor::word(self : DateCursor) -> String {
  let start = self.i
  while !self.eof() {
    let c = self.at()
    if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0xC0 {
      self.i += 1
    } else {
      break
    }
  }
  self.s.unsafe_substring(start~, end=self.i).to_lower()
}

///|
/// Skips the date word 'de' (and following blanks) of Spanish and
/// Portuguese cultures.
fn DateCursor::skip_date_word(self : DateCursor) -> Unit {
  let lang = self.cult.name.to_lower()
  if !(lang.has_prefix("es") || lang.has_prefix("pt")) {
    return
  }
  let save = self.i
  if self.word() == "de" && self.skip_ws() {
    return
  }
  self.i = save
}

///|
/// Month number of a (lowercased) month name of the culture: full,
/// abbreviated or genitive.
fn DateCursor::month_of(self : DateCursor, w : String) -> Int? {
  if w == "" {
    return None
  }
  let c = self.cult
  for i in 0..<12 {
    for names in [c.months, c.months_abbr, c.months_gen, c.months_abbr_gen] {
      if names[i].to_lower() == w {
        return Some(i + 1)
      }
    }
  }
  None
}

///|
/// 0 = Sunday … 6 = Saturday, for a full or abbreviated day name.
fn DateCursor::weekday_of(self : DateCursor, w : String) -> Int? {
  if w == "" {
    return None
  }
  for i in 0..<7 {
    if self.cult.days[i].to_lower() == w ||
      self.cult.days_abbr[i].to_lower() == w {
      return Some(i)
    }
  }
  None
}

///|
/// Year of a two-digit year: .NET's default TwoDigitYearMax is 2049
/// (captured: '12/31/30' is 2030, '12/31/99' 1999).
fn two_digit_year(y : Int) -> Int {
  if y <= 49 {
    2000 + y
  } else {
    1900 + y
  }
}

///|
priv struct DateParts {
  year : Int
  month : Int
  day : Int
}

///|
/// The date part at the cursor, or None (cursor restored) when no modelled
/// date shape starts here.
fn DateCursor::date_part(self : DateCursor) -> DateParts? {
  let start = self.i
  let restore = () => {
    self.i = start
    None
  }
  if net_digit(self.at()) {
    guard self.number() is Some((a, alen)) else { return restore() }
    let sep = self.at()
    if alen == 4 && (sep == 0x2D || sep == 0x2F || sep == 0x2E) {
      // yyyy-M-d, yyyy/M/d, yyyy.M.d, yyyy-M
      self.i += 1
      guard self.number() is Some((m, mlen)) && mlen <= 2 else {
        return restore()
      }
      if self.eat(sep) {
        guard self.number() is Some((d, dlen)) && dlen <= 2 else {
          return restore()
        }
        return Some({ year: a, month: m, day: d, })
      }
      if sep == 0x2D && self.at() != 0x3A {
        return Some({ year: a, month: m, day: 1, })
      }
      return restore()
    }
    if alen <= 2 && sep == 0x2E && self.order == 1 {
      // d. MMMM yyyy (captured: '2. Januar 2024' in de-DE)
      let save = self.i
      self.i += 1
      if self.skip_ws() {
        guard self.month_of(self.word()) is Some(m) else { return restore() }
        guard self.skip_ws() else { return restore() }
        guard self.number() is Some((y, 4)) else { return restore() }
        return Some({ year: y, month: m, day: a, })
      }
      self.i = save
    }
    if alen <= 2 && (sep == 0x2F || sep == 0x2E) {
      // M/d/yyyy, M/d/yy, M.d.yyyy (d/M/yyyy in day-first cultures)
      if self.order == 2 {
        return restore()
      }
      self.i += 1
      guard self.number() is Some((d, dlen)) && dlen <= 2 else {
        return restore()
      }
      guard self.eat(sep) else { return restore() }
      guard self.number() is Some((y, ylen)) && (ylen == 2 || ylen == 4) else {
        return restore()
      }
      let year = if ylen == 2 { two_digit_year(y) } else { y }
      if self.order == 1 {
        return Some({ year, month: d, day: a, })
      }
      return Some({ year, month: a, day: d, })
    }
    if alen <= 2 &&
      sep == 0x2D &&
      self.order == 1 &&
      self.i + 1 < self.s.length() &&
      net_digit(self.s.code_unit_at(self.i + 1).to_int()) {
      // d-M-yyyy in day-first cultures (captured: '23-11-2009' in nl-NL)
      self.i += 1
      guard self.number() is Some((m, mlen)) && mlen <= 2 else {
        return restore()
      }
      guard self.eat(0x2D) else { return restore() }
      guard self.number() is Some((y, ylen)) && (ylen == 2 || ylen == 4) else {
        return restore()
      }
      let year = if ylen == 2 { two_digit_year(y) } else { y }
      return Some({ year, month: m, day: a, })
    }
    if alen <= 2 && sep == 0x2D {
      // d-MMM-yyyy
      self.i += 1
      guard self.month_of(self.word()) is Some(m) else { return restore() }
      guard self.eat(0x2D) else { return restore() }
      guard self.number() is Some((y, 4)) else { return restore() }
      return Some({ year: y, month: m, day: a, })
    }
    if self.skip_ws() {
      if alen <= 2 {
        // d MMM yyyy; Spanish/Portuguese write 'd de MMMM de yyyy'
        // (captured: '23 de novembro de 2009' in pt-BR)
        self.skip_date_word()
        guard self.month_of(self.word()) is Some(m) else { return restore() }
        guard self.skip_ws() else { return restore() }
        self.skip_date_word()
        guard self.number() is Some((y, 4)) else { return restore() }
        return Some({ year: y, month: m, day: a, })
      }
      if alen == 4 {
        // yyyy MMM d
        guard self.month_of(self.word()) is Some(m) else { return restore() }
        guard self.skip_ws() else { return restore() }
        guard self.number() is Some((d, dlen)) && dlen <= 2 else {
          return restore()
        }
        return Some({ year: a, month: m, day: d, })
      }
    }
    return restore()
  }
  // MMMM d, yyyy / MMM d yyyy / MMMM yyyy
  guard self.month_of(self.word()) is Some(m) else { return restore() }
  guard self.skip_ws() else { return restore() }
  guard self.number() is Some((a, alen)) else { return restore() }
  if alen == 4 {
    return Some({ year: a, month: m, day: 1, })
  }
  guard alen <= 2 else { return restore() }
  ignore(self.eat(0x2C))
  guard self.skip_ws() else { return restore() }
  guard self.number() is Some((y, 4)) else { return restore() }
  Some({ year: y, month: m, day: a, })
}

///|
priv struct TimeParts {
  hour : Int
  minute : Int
  second : Int
  /// fraction of a second in 100 ns ticks, rounded (may reach 10^7)
  ticks : Int64
  /// 0 none, 1 AM, 2 PM
  designator : Int
}

///|
fn DateCursor::designator(self : DateCursor) -> Int {
  let save = self.i
  ignore(self.skip_ws())
  let w = self.word()
  if w != "" && w == self.cult.am.to_lower() {
    1
  } else if w != "" && w == self.cult.pm.to_lower() {
    2
  } else {
    self.i = save
    0
  }
}

///|
/// `H:mm[:ss[.fffffff]] [AM|PM]` or `H AM|PM`.
fn DateCursor::time_part(self : DateCursor) -> TimeParts? {
  let start = self.i
  guard self.number() is Some((h, hlen)) && hlen <= 2 else {
    self.i = start
    return None
  }
  if !self.eat(0x3A) {
    let d = self.designator()
    if d == 0 {
      self.i = start
      return None
    }
    return Some({ hour: h, minute: 0, second: 0, ticks: 0L, designator: d, })
  }
  guard self.number() is Some((mi, 2)) else {
    self.i = start
    return None
  }
  let mut sec = 0
  let mut ticks = 0L
  if self.eat(0x3A) {
    guard self.number() is Some((s, 2)) else {
      self.i = start
      return None
    }
    sec = s
    if self.at() == 0x2E {
      self.i += 1
      let fstart = self.i
      while !self.eof() && net_digit(self.at()) {
        self.i += 1
      }
      let f = self.s.unsafe_substring(start=fstart, end=self.i)
      if f.length() == 0 {
        self.i = start
        return None
      }
      // 100 ns ticks, rounded half up at the 8th digit
      let mut t = 0L
      for k in 0..<7 {
        t = t * 10L +
          (if k < f.length() {
            (f.code_unit_at(k).to_int() - 0x30).to_int64()
          } else {
            0L
          })
      }
      if f.length() > 7 && f.code_unit_at(7).to_int() >= 0x35 {
        t += 1L
      }
      ticks = t
    }
  }
  let d = self.designator()
  Some({ hour: h, minute: mi, second: sec, ticks, designator: d, })
}

///|
/// Parses date/time text for a PARSE target type `t`.
fn parse_net_datetime(
  text : String,
  t : @types.SqlType,
  cult : CultureData,
) -> ParsedDate {
  if cult.calendar != 0 {
    return ParsedUnsupported("culture \{cult.name} calendar")
  }
  let mut has_digit = false
  let mut all_digits = true
  let s = text.trim(chars=" \t\n\r\u{0B}\u{0C}").to_owned()
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if net_digit(c) {
      has_digit = true
    } else {
      all_digits = false
    }
  }
  if !has_digit || all_digits {
    return ParsedInvalid
  }
  let cur : DateCursor = { s, i: 0, cult, order: date_order(cult), }
  // optional day name: `Monday, ` / `Mon, `
  let mut weekday : Int? = None
  if !net_digit(cur.at()) {
    let save = cur.i
    let w = cur.word()
    match cur.weekday_of(w) {
      Some(d) if cur.eat(0x2C) => {
        weekday = Some(d)
        ignore(cur.skip_ws())
      }
      _ => cur.i = save
    }
  }
  let date = cur.date_part()
  let mut time : TimeParts? = None
  if date is Some(_) {
    if !cur.eof() {
      let sep = cur.eat(0x54) || cur.eat(0x74) || cur.skip_ws()
      if sep && !cur.eof() {
        time = cur.time_part()
        if time is None {
          // `... GMT` / `Z` right after the date is not modelled
          return ParsedUnsupported("unrecognised text after the date")
        }
      }
    }
  } else {
    time = cur.time_part()
    if time is None {
      return ParsedUnsupported("unrecognised date format")
    }
  }
  // zone designator
  let mut offset : Int? = None
  ignore(cur.skip_ws())
  if !cur.eof() {
    let c = cur.at()
    if c == 0x5A || c == 0x7A {
      cur.i += 1
      offset = Some(0)
    } else if c == 0x2B || c == 0x2D {
      cur.i += 1
      guard cur.number() is Some((oh, 2)) else {
        return ParsedUnsupported("unrecognised offset")
      }
      guard cur.eat(0x3A) else {
        return ParsedUnsupported("unrecognised offset")
      }
      guard cur.number() is Some((om, 2)) else {
        return ParsedUnsupported("unrecognised offset")
      }
      if oh > 14 || om > 59 || oh * 60 + om > 840 {
        return ParsedUnsupported("offset out of range")
      }
      offset = Some(if c == 0x2D { -(oh * 60 + om) } else { oh * 60 + om })
    } else {
      let w = cur.word()
      if w == "gmt" || w == "utc" {
        offset = Some(0)
      } else {
        return ParsedUnsupported("unrecognised text")
      }
    }
    ignore(cur.skip_ws())
    if !cur.eof() {
      return ParsedUnsupported("unrecognised text")
    }
  }
  if offset is Some(_) && !(t is DateTimeOffset(_)) {
    // .NET converts a zoned time to the server's local time zone
    return ParsedUnsupported("time zone designator")
  }
  if date is None && !(t is Time(_)) {
    // .NET completes a time-only text with today's date (the clock)
    return ParsedUnsupported("text without a date")
  }
  let (days, tod) = match date {
    Some(d) => {
      if d.year < 1 ||
        d.year > 9999 ||
        d.month < 1 ||
        d.month > 12 ||
        d.day < 1 ||
        d.day > month_days(d.year, d.month) {
        return ParsedInvalid
      }
      let days = @types.days_from_civil(d.year, d.month, d.day)
      match weekday {
        Some(w) if weekday_index(days) != w => return ParsedInvalid
        _ => ()
      }
      (days, 0L)
    }
    None => (@types.DAYS_TO_1900, 0L)
  }
  let tod = match time {
    None => tod
    Some(tp) => {
      let mut h = tp.hour
      match tp.designator {
        1 =>
          if h > 12 {
            return ParsedUnsupported("hour above 12 with AM")
          } else if h == 12 {
            h = 0
          }
        2 => if h < 12 { h += 12 }
        _ => ()
      }
      if h > 23 || tp.minute > 59 || tp.second > 59 {
        return ParsedInvalid
      }
      (h * 3600 + tp.minute * 60 + tp.second).to_int64() *
      @types.TICKS_PER_SECOND +
      tp.ticks
    }
  }
  let ticks = days.to_int64() * @types.TICKS_PER_DAY + tod
  if ticks > MAX_TICKS {
    return ParsedOverflow
  }
  ParsedOk(ticks, offset)
}
