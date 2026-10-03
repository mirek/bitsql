// The Hijri calendar of CONVERT styles 130 and 131: Microsoft's "Kuwaiti
// algorithm" (the arithmetic calendar of .NET's HijriCalendar, adjustment
// 0). Checked against SQL Server for 20 dates from 1753 to 9999 and both
// directions (harness/corpus/conversion/hijri.cases.json).

///|
/// Days before each Hijri month (month 12 has 30 days in leap years).
let hijri_month_days : Array[Int] = [
  0, 30, 59, 89, 118, 148, 177, 207, 236, 266, 295, 325, 355,
]

///|
/// Arabic month names as SQL Server prints them (style 130, captured).
let hijri_month_names : Array[String] = [
  "\u{0645}\u{062D}\u{0631}\u{0645}", "\u{0635}\u{0641}\u{0631}", "\u{0631}\u{0628}\u{064A}\u{0639} \u{0627}\u{0644}\u{0627}\u{0648}\u{0644}",
  "\u{0631}\u{0628}\u{064A}\u{0639} \u{0627}\u{0644}\u{062B}\u{0627}\u{0646}\u{064A}",
  "\u{062C}\u{0645}\u{0627}\u{062F}\u{0649} \u{0627}\u{0644}\u{0627}\u{0648}\u{0644}\u{0649}",
  "\u{062C}\u{0645}\u{0627}\u{062F}\u{0649} \u{0627}\u{0644}\u{062B}\u{0627}\u{0646}\u{064A}\u{0629}",
  "\u{0631}\u{062C}\u{0628}", "\u{0634}\u{0639}\u{0628}\u{0627}\u{0646}", "\u{0631}\u{0645}\u{0636}\u{0627}\u{0646}",
  "\u{0634}\u{0648}\u{0627}\u{0644}", "\u{0630}\u{0648} \u{0627}\u{0644}\u{0642}\u{0639}\u{062F}\u{0629}",
  "\u{0630}\u{0648} \u{0627}\u{0644}\u{062D}\u{062C}\u{0629}",
]

///|
fn hijri_leap(y : Int) -> Bool {
  (y * 11 + 14) % 30 < 11
}

///|
fn hijri_year_days(y : Int) -> Int {
  if hijri_leap(y) {
    355
  } else {
    354
  }
}

///|
/// 1-based absolute day (0001-01-01 = 1) of the last day before Hijri year
/// `y`.
fn hijri_days_up_to(y : Int) -> Int {
  let n30 = (y - 1) / 30 * 30
  let mut left = y - n30 - 1
  let mut n = n30 * 10631 / 30 + 227013
  while left > 0 {
    n += 354 + (if hijri_leap(left) { 1 } else { 0 })
    left -= 1
  }
  n
}

///|
/// Days in a Hijri month.
fn hijri_month_length(y : Int, m : Int) -> Int {
  if m == 12 {
    if hijri_leap(y) {
      30
    } else {
      29
    }
  } else if m % 2 == 1 {
    30
  } else {
    29
  }
}

///|
/// A valid Hijri date (years 1..9999).
fn hijri_valid(y : Int, m : Int, d : Int) -> Bool {
  y >= 1 &&
  y <= 9999 &&
  m >= 1 &&
  m <= 12 &&
  d >= 1 &&
  d <= hijri_month_length(y, m)
}

///|
/// Hijri (year, month, day) of a date (days since 0001-01-01), or None
/// before 622-07-18 (proleptic Gregorian), where the calendar starts.
fn hijri_from_days(days : Int) -> (Int, Int, Int)? {
  let mut n = days + 1
  if n <= hijri_days_up_to(1) {
    return None
  }
  let mut y = (n - 227013) * 30 / 10631 + 1
  let mut before = hijri_days_up_to(y)
  let len = hijri_year_days(y)
  if n <= before {
    y -= 1
    before -= hijri_year_days(y)
  } else if n > before + len {
    before += len
    y += 1
  }
  n -= before
  let mut m = 1
  while m <= 12 && n > hijri_month_days[m - 1] {
    m += 1
  }
  m -= 1
  Some((y, m, n - hijri_month_days[m - 1]))
}

///|
/// Days since 0001-01-01 of a valid Hijri date.
fn days_from_hijri(y : Int, m : Int, d : Int) -> Int {
  hijri_days_up_to(y) + hijri_month_days[m - 1] + d - 1
}

///|
/// 9814: a date before the Hijri calendar (captured, state 0).
fn hijri_range_error() -> SqlError {
  sql_error(
    9814,
    "The date provided is before the start of the Hijri calendar which in Microsoft's 'Kuwaiti Algorithm' is July 15th, 622 C.E. (Julian calendar) or July 18th, 622 C.E (proleptic Gregorian calendar).",
    state=0,
  )
}
