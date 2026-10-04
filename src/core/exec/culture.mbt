// .NET culture data for FORMAT and PARSE: the record type of the generated
// table (culture_data.mbt, read back from the oracle by
// harness/gen/cultures.mjs), culture-name validation and lookup, and the
// culture of each SET LANGUAGE language.
//
// Name rules (captured probes, SQL Server 17.0.5005 on Linux): '_' reads as
// '-', names are case-insensitive; a well-formed tag whose language has no
// data of its own ('xx-XX', 'a-b' is not well-formed) formats like the
// invariant culture; anything else ('x', 'abcd', 'en-US ', 'German', '')
// is 9818. A known language with a region bitsql has no data for is an
// emulator error rather than a guess (the oracle falls back to the
// language, but real regions differ: de-CH groups with U+2019).

///|
priv struct CultureData {
  name : String
  n_dec : String
  n_group : String
  n_sizes : Array[Int]
  /// negative number pattern, '#' = the number
  n_neg : String
  n_digits : Int
  c_symbol : String
  c_dec : String
  c_group : String
  c_sizes : Array[Int]
  c_pos : String
  c_neg : String
  c_digits : Int
  p_dec : String
  p_group : String
  p_sizes : Array[Int]
  p_pos : String
  p_neg : String
  p_digits : Int
  neg_sign : String
  percent : String
  permille : String
  /// 0 Gregorian, 1 Thai Buddhist (year + 543), 2 Hijri (not emulated)
  calendar : Int
  months : Array[String]
  months_abbr : Array[String]
  months_gen : Array[String]
  months_abbr_gen : Array[String]
  /// Sunday first
  days : Array[String]
  days_abbr : Array[String]
  am : String
  pm : String
  date_sep : String
  time_sep : String
  pat_d : String
  pat_long_d : String
  pat_t : String
  pat_long_t : String
  pat_f : String
  pat_long_f : String
  pat_g : String
  pat_long_g : String
  pat_m : String
  pat_y : String
}

///|
priv enum CultureLookup {
  Found(CultureData)
  /// 9818: not a culture name
  Invalid
  /// a real culture bitsql has no data for
  Missing
}

///|
fn is_ascii_letter(c : Int) -> Bool {
  (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}

///|
fn is_ascii_alnum(c : Int) -> Bool {
  is_ascii_letter(c) || (c >= 0x30 && c <= 0x39)
}

///|
fn all_units(s : String, f : (Int) -> Bool) -> Bool {
  for i in 0..<s.length() {
    if !f(s.code_unit_at(i).to_int()) {
      return false
    }
  }
  true
}

///|
/// Well-formed culture name (subtags already split on '-'). Captured:
/// 'xx', 'xx-XX', 'ab-123', 'ab-cd-ef', 'x-foo', 'i-klingon', 'a-b', 'a-bc',
/// 'en-US-x-foo', 'de-DE-u-nu-arab' are accepted; 'x', '1', 'abcd',
/// 'abcde', 'ab-c', 'ab-1', 'ab-12', 'ab-c1', 'ab-cdefghi', 'ab-',
/// 'en--US', 'root' are not. Unverified beyond these shapes.
fn well_formed_culture(parts : Array[String]) -> Bool {
  if parts.iter().any(p => p.length() == 0 || p.length() > 8) {
    return false
  }
  let first = parts[0]
  let lower = first.to_lower()
  if lower.length() == 1 && all_units(lower, is_ascii_letter) {
    return parts.length() > 1 &&
      parts[1:].iter().all(p => all_units(p, is_ascii_alnum))
  }
  if first.length() < 2 ||
    first.length() > 3 ||
    !all_units(first, is_ascii_letter) {
    return false
  }
  let mut i = 1
  while i < parts.length() {
    let p = parts[i]
    if p.length() == 1 {
      if !all_units(p, is_ascii_alnum) || i + 1 >= parts.length() {
        return false
      }
      let private = p.to_lower() == "x"
      i += 1
      while i < parts.length() && (private || parts[i].length() > 1) {
        let q = parts[i]
        if !all_units(q, is_ascii_alnum) || (!private && q.length() < 2) {
          return false
        }
        i += 1
      }
      continue
    }
    let ok = (p.length() <= 4 && all_units(p, is_ascii_letter)) ||
      (p.length() == 3 && all_units(p, c => c >= 0x30 && c <= 0x39))
    if !ok {
      return false
    }
    i += 1
  }
  true
}

///|
fn find_culture(name : String) -> CultureLookup {
  let norm = name.replace_all(old="_", new="-")
  let parts = norm.split("-").map(p => p.to_owned()).collect()
  if !well_formed_culture(parts) {
    return Invalid
  }
  let lower = norm.to_lower()
  for c in culture_table {
    if c.name.to_lower() == lower {
      return Found(c)
    }
  }
  let lang = parts[0].to_lower()

  if lang.length() == 1 ||
    (lang.length() == 2 && !known_languages.contains(lang)) {
    return Found(invariant_culture())
  }
  Missing
}

///|
fn invariant_culture() -> CultureData {
  culture_table[0]
}

///|
/// The culture of a SET LANGUAGE language (@@LANGUAGE name), from
/// sys.syslanguages.lcid (captured: Deutsch formats like de-DE, British
/// like en-GB, 日本語 like ja-JP).
fn language_culture(language : String) -> String? {
  match language {
    "us_english" => Some("en-US")
    "Deutsch" => Some("de-DE")
    "Français" => Some("fr-FR")
    "日本語" => Some("ja-JP")
    "Dansk" => Some("da-DK")
    "Español" => Some("es-ES")
    "Italiano" => Some("it-IT")
    "Nederlands" => Some("nl-NL")
    "Norsk" => Some("nn-NO")
    "Português" => Some("pt-PT")
    "Suomi" => Some("fi-FI")
    "Svenska" => Some("sv-SE")
    "čeština" => Some("cs-CZ")
    "magyar" => Some("hu-HU")
    "polski" => Some("pl-PL")
    "română" => Some("ro-RO")
    "hrvatski" => Some("hr-HR")
    "slovenčina" => Some("sk-SK")
    "slovenski" => Some("sl-SI")
    "ελληνικά" => Some("el-GR")
    "български" => Some("bg-BG")
    "русский" => Some("ru-RU")
    "Türkçe" => Some("tr-TR")
    "British" => Some("en-GB")
    "eesti" => Some("et-EE")
    "latviešu" => Some("lv-LV")
    "lietuvių" => Some("lt-LT")
    "Português (Brasil)" => Some("pt-BR")
    "繁體中文" => Some("zh-TW")
    "한국어" => Some("ko-KR")
    "简体中文" => Some("zh-CN")
    "Arabic" => Some("ar-SA")
    "ไทย" => Some("th-TH")
    "norsk (bokmål)" => Some("nb-NO")
    _ => None
  }
}

///|
fn culture_not_supported(name : String) -> @types.SqlError {
  @types.sql_error(
    9818,
    "The culture parameter '\{name}' provided in the function call is not supported.",
  )
}

///|
/// The culture of an explicit FORMAT/PARSE culture argument (raises 9818
/// for a malformed name, an emulator error for real cultures without data).
fn resolve_culture(
  name : String,
  feature : String,
  number~ : Int,
) -> CultureData raise @types.SqlError {
  match find_culture(name) {
    Found(c) => c
    Invalid => raise culture_not_supported(name)
    Missing =>
      raise @types.not_supported("\{feature} culture '\{name}'", number~)
  }
}

///|
/// The session language's culture (FORMAT/PARSE without a culture).
fn session_culture(
  ctx : Ctx,
  feature : String,
  number~ : Int,
) -> CultureData raise @types.SqlError {
  let lang = match global(ctx, Language) {
    String(s) => s
    _ => "us_english"
  }
  match language_culture(lang) {
    Some(n) => resolve_culture(n, feature, number~)
    None =>
      raise @types.not_supported(
        "\{feature} under SET LANGUAGE \{lang}",
        number~,
      )
  }
}
