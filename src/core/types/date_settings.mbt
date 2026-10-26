// Session settings that string ↔ date/time conversions depend on: SET
// DATEFORMAT (numeric date order) and SET LANGUAGE (month names when
// parsing and in styles 0/100/106/107/109/113, DATENAME, default date
// order and first weekday). Rules: docs/reference/date-strings.md
// ("DATEFORMAT and LANGUAGE"); data: language_data.mbt.

///|
/// SET DATEFORMAT: the order of the parts of a numeric date.
pub(all) enum DateFormat {
  Mdy
  Dmy
  Ymd
  Ydm
  Myd
  Dym
} derive(Eq, Debug)

///|
/// A DATEFORMAT name (case-insensitive), or None (2741).
pub fn DateFormat::parse(text : String) -> DateFormat? {
  match text.to_lower() {
    "mdy" => Some(Mdy)
    "dmy" => Some(Dmy)
    "ymd" => Some(Ymd)
    "ydm" => Some(Ydm)
    "myd" => Some(Myd)
    "dym" => Some(Dym)
    _ => None
  }
}

///|
/// The lower-case name SQL Server reports (DBCC USEROPTIONS,
/// sys.dm_exec_sessions.date_format).
pub fn DateFormat::name(self : DateFormat) -> String {
  match self {
    Mdy => "mdy"
    Dmy => "dmy"
    Ymd => "ymd"
    Ydm => "ydm"
    Myd => "myd"
    Dym => "dym"
  }
}

///|
/// A row of sys.syslanguages plus its INFO 5703 text.
pub(all) struct Language {
  langid : Int
  name : String
  alias_name : String
  dateformat : DateFormat
  datefirst : Int
  months : Array[String]
  short_months : Array[String]
  /// Monday first.
  days : Array[String]
  lcid : Int
  msglangid : Int
  /// "Changed language setting to …." in the language itself.
  changed_message : String
}

///|
let language_rows : Ref[Array[Language]?] = Ref(None)

///|
/// The languages of sys.syslanguages, by langid (language_data.mbt).
pub fn languages() -> Array[Language] {
  if language_rows.val is Some(rows) {
    return rows
  }
  let rows = language_text
    .split("\n")
    .map(line => {
      let f = line.split("|").collect()
      let list = (i : Int) => f[i].split(",").map(p => p.to_owned()).collect()
      {
        langid: @tabletext.int(f[0]),
        name: f[1].to_owned(),
        alias_name: f[2].to_owned(),
        dateformat: DateFormat::parse(f[3].to_owned()).unwrap(),
        datefirst: @tabletext.int(f[4]),
        months: list(5),
        short_months: list(6),
        days: list(7),
        lcid: @tabletext.int(f[8]),
        msglangid: @tabletext.int(f[9]),
        changed_message: f[10].to_owned(),
      }
    })
    .collect()
  language_rows.val = Some(rows)
  rows
}

///|
/// The language with `langid` (us_english for unknown ids).
pub fn language(langid : Int) -> Language {
  match languages().get(langid) {
    Some(l) => l
    None => languages()[0]
  }
}

///|
/// SET LANGUAGE: a language by name or alias, compared like the server's
/// default collation (case-insensitive, accent-sensitive).
pub fn find_language(name : String) -> Language? {
  for l in languages() {
    if compare_strings(l.name, name, default_collation) == 0 ||
      compare_strings(l.alias_name, name, default_collation) == 0 {
      return Some(l)
    }
  }
  None
}

///|
/// What string ↔ date/time conversions read from the session.
pub(all) struct DateSettings {
  format : DateFormat
  /// sys.syslanguages langid
  language : Int
} derive(Eq, Debug)

///|
/// SQL Server's defaults (and bitsql's before a SET): us_english, mdy.
pub let default_date_settings : DateSettings = { format: Mdy, language: 0, }

///|
/// The month (1-12) a word names in `lang`: its full or short name, any
/// case, accents significant (captured: settings/language, 'MÄRZ' and
/// 'Mär' under German; 'aout', 'March' fail under French).
fn month_of_word(word : String, lang : Language) -> Int? {
  for i, m in lang.months {
    if compare_strings(m, word, default_collation) == 0 {
      return Some(i + 1)
    }
  }
  for i, m in lang.short_months {
    if compare_strings(m, word, default_collation) == 0 {
      return Some(i + 1)
    }
  }
  None
}
