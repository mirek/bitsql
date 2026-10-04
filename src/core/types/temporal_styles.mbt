// Date/time → character CONVERT styles (us_english).
//
// Every rule here is captured (msduck gaps-conversion format-* for all six
// temporal types × 47 styles, harness/corpus/conversion/hijri):
//
// - date-only styles (1-7, 10-12, 23, 101-107, 110-112) print no time and
//   no offset; on time they fail with 8114 state 5;
// - time-only styles (8, 24, 108; 14, 114) print the offset of a
//   datetimeoffset; 8/24/108 on date fail with 8114, 14/114 with 281;
// - datetime/smalldatetime write milliseconds as `:mmm` in styles 9, 13,
//   14, 109, 113, 114, 130, 131 and `.mmm` in 21, 25, 121, 126, 127; the
//   other types write the declared number of fraction digits after `.`;
// - the AM/PM styles (0, 9, 22, 100, 109, 130, 131) space-pad the hour to
//   two characters, except styles 0/9/100/109 of a time value alone;
// - 126 and 127 drop an all-zero fraction (any type); 127 writes a
//   datetimeoffset in UTC with `Z`, 126 with `+hh:mm`;
// - 115 is `hhmmss` (date: `000000`, time: 8114);
// - 130/131 are the Hijri calendar (hijri.mbt), day space-padded;
// - 26-35 are undocumented day/month/year orders (see the match below);
// - any other style is 281 state 1.

///|
fn pad2_space(n : Int) -> String {
  if n < 10 {
    " " + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad4(n : Int) -> String {
  let s = n.to_string()
  if s.length() >= 4 {
    s
  } else {
    String::make(4 - s.length(), '0') + s
  }
}

///|
/// 281: a style number that does not exist for this source type.
fn invalid_style(style : Int, from : SqlType) -> SqlError {
  sql_error(
    281,
    "\{style} is not a valid style number when converting from \{from.base_name()} to a character string.",
  )
}

///|
/// Text of a temporal value for a CONVERT style (None = CAST). `target`
/// names the character type in 8114 messages.
///
/// CAST of date/time/datetime2/datetimeoffset is ISO with the declared
/// number of fraction digits (`2024-03-01 00:00:00.00 +01:30`); CAST of
/// datetime/smalldatetime is style 0 (msduck temporal-guid-format).
pub fn render_temporal(
  v : Value,
  from : SqlType,
  style : Int?,
  target? : String = "varchar",
  dates? : DateSettings = default_date_settings,
) -> String raise SqlError {
  let inst = instant_of(v, from)
  let days = inst.days.unwrap_or(DAYS_TO_1900)
  let legacy = from is (DateTime | SmallDateTime)
  // display ticks: legacy datetime shows whole milliseconds
  let time = match v {
    DateTime(_, u) => {
      let sec = u / 300
      let ms = (u % 300 * 10 + 1) / 3
      sec.to_int64() * TICKS_PER_SECOND + ms.to_int64() * 10_000L
    }
    _ => inst.time.unwrap_or(0L)
  }
  let digits = match from {
    Time(s) | DateTime2(s) | DateTimeOffset(s) => s
    _ => 3
  }
  let date_only = from is Date
  let time_only = from is Time(_)
  let off = match inst.offset {
    Some(o) => " " + format_offset(o)
    None => ""
  }
  let (y, m, d) = civil_from_days(days)
  let yyyy = pad4(y)
  let yy = pad2s(y % 100)
  let mm = pad2s(m)
  let dd = pad2s(d)
  // the session language's short month names (captured: settings/language
  // styles, 'Mär  4 2024  5:06AM' under German)
  let mon = language(dates.language).short_months[m - 1]
  let secs = time / TICKS_PER_SECOND
  let frac_ticks = time % TICKS_PER_SECOND
  let h24 = (secs / 3600L).to_int()
  let mi = pad2s((secs / 60L % 60L).to_int())
  let ss = pad2s((secs % 60L).to_int())
  let hms = pad2s(h24) + ":" + mi + ":" + ss
  let frac = (sep : String) => {
    if digits <= 0 {
      ""
    } else {
      sep + pad_n(frac_ticks, 7).unsafe_substring(start=0, end=digits)
    }
  }
  let msep = if legacy { ":" } else { "." }
  let ampm = if h24 < 12 { "AM" } else { "PM" }
  let h12 = if h24 % 12 == 0 { 12 } else { h24 % 12 }
  let ymd = yyyy + "-" + mm + "-" + dd
  let no_conversion = () => {
    sql_error(
      8114,
      "Error converting data type \{from.base_name()} to \{target}.",
      state=5,
    )
  }
  let n = match style {
    None =>
      return if legacy {
        render_temporal(v, from, Some(0), target~, dates~)
      } else if date_only {
        ymd
      } else if time_only {
        format_time_iso(time, digits)
      } else {
        ymd + " " + format_time_iso(time, digits) + off
      }
    Some(n) => n
  }
  // date part of the numeric date-only styles
  let numeric_date = (n : Int) => {
    let year = if n >= 100 { yyyy } else { yy }
    match n % 100 {
      1 => Some(mm + "/" + dd + "/" + year)
      2 => Some(year + "." + mm + "." + dd)
      3 => Some(dd + "/" + mm + "/" + year)
      4 => Some(dd + "." + mm + "." + year)
      5 => Some(dd + "-" + mm + "-" + year)
      6 => Some(dd + " " + mon + " " + year)
      7 => Some(mon + " " + dd + ", " + year)
      10 => Some(mm + "-" + dd + "-" + year)
      11 => Some(year + "/" + mm + "/" + dd)
      12 => Some(year + mm + dd)
      _ => None
    }
  }
  let mon_day_year = mon + " " + pad2_space(d) + " " + yyyy
  match n {
    0 | 100 =>
      if date_only {
        mon_day_year
      } else if time_only {
        h12.to_string() + ":" + mi + ampm
      } else {
        mon_day_year + " " + pad2_space(h12) + ":" + mi + ampm + off
      }
    9 | 109 =>
      if date_only {
        mon_day_year
      } else if time_only {
        h12.to_string() + ":" + mi + ":" + ss + frac(".") + ampm
      } else {
        mon_day_year +
        " " +
        pad2_space(h12) +
        ":" +
        mi +
        ":" +
        ss +
        frac(msep) +
        ampm +
        off
      }
    13 | 113 =>
      if date_only {
        dd + " " + mon + " " + yyyy
      } else if time_only {
        hms + frac(".")
      } else {
        dd + " " + mon + " " + yyyy + " " + hms + frac(msep) + off
      }
    14 | 114 =>
      if date_only {
        raise invalid_style(n, from)
      } else if time_only {
        hms + frac(".")
      } else {
        hms + frac(msep) + off
      }
    8 | 24 | 108 => if date_only { raise no_conversion() } else { hms + off }
    20 | 120 =>
      if date_only {
        ymd
      } else if time_only {
        hms
      } else {
        ymd + " " + hms + off
      }
    21 | 25 | 121 =>
      if date_only {
        ymd
      } else if time_only {
        hms + frac(".")
      } else {
        ymd + " " + hms + frac(".") + off
      }
    22 => {
      let t = pad2_space(h12) + ":" + mi + ":" + ss + " " + ampm
      if date_only {
        mm + "/" + dd + "/" + yy
      } else if time_only {
        t
      } else {
        mm + "/" + dd + "/" + yy + " " + t + off
      }
    }
    23 => if time_only { raise no_conversion() } else { ymd }
    // undocumented (captured, harness/corpus/conversion/output-styles):
    // 26-30 are yyyy-dd-mm, mm-dd-yyyy, mm-yyyy-dd, dd-mm-yyyy, dd-yyyy-mm
    // with the 21-style time; 31-35 the same dates alone
    26 | 27 | 28 | 29 | 30 | 31 | 32 | 33 | 34 | 35 => {
      let date = match n % 5 {
        1 => yyyy + "-" + dd + "-" + mm
        2 => mm + "-" + dd + "-" + yyyy
        3 => mm + "-" + yyyy + "-" + dd
        4 => dd + "-" + mm + "-" + yyyy
        _ => dd + "-" + yyyy + "-" + mm
      }
      if n >= 31 {
        if time_only {
          raise no_conversion()
        }
        date
      } else if date_only {
        date
      } else if time_only {
        hms + frac(".")
      } else {
        date + " " + hms + frac(".") + off
      }
    }
    115 =>
      if date_only {
        "000000"
      } else if time_only {
        raise no_conversion()
      } else {
        pad2s(h24) + mi + ss
      }
    126 | 127 => {
      let nz = (t : Int64) => {
        if t % TICKS_PER_SECOND == 0L {
          format_time_iso(t, 0)
        } else {
          format_time_iso(t, digits)
        }
      }
      if date_only {
        ymd
      } else if time_only {
        nz(time)
      } else {
        match (n, v) {
          (127, DateTimeOffset(utc, _)) => {
            let ud = (utc / TICKS_PER_DAY).to_int()
            format_date_iso(ud) + "T" + nz(utc % TICKS_PER_DAY) + "Z"
          }
          _ =>
            ymd +
            "T" +
            nz(time) +
            (match inst.offset {
              Some(o) => format_offset(o)
              None => ""
            })
        }
      }
    }
    130 | 131 => {
      let t = pad2_space(h12) + ":" + mi + ":" + ss
      if time_only {
        t + frac(".") + ampm
      } else {
        let (hy, hm, hd) = match hijri_from_days(days) {
          Some(h) => h
          None => raise hijri_range_error()
        }
        let date = if n == 130 {
          pad2_space(hd) + " " + hijri_month_names[hm - 1] + " " + pad4(hy)
        } else {
          pad2_space(hd) + "/" + pad2s(hm) + "/" + pad4(hy)
        }
        if date_only {
          date
        } else {
          date + " " + t + frac(msep) + ampm + off
        }
      }
    }
    _ =>
      match numeric_date(n) {
        Some(_) if n > 112 || (n > 12 && n < 101) =>
          raise invalid_style(n, from)
        Some(text) => if time_only { raise no_conversion() } else { text }
        None => raise invalid_style(n, from)
      }
  }
}
