// Collations: the subset of SQL Server collations bitsql models.
//
// Modelled families (anything else: `Collation::parse` returns None and the
// binder raises EMU_COLLATION_NOT_SUPPORTED):
//
// - `SQL_Latin1_General_CP1_{CI|CS}_{AS|AI}`: legacy "SQL" collations. For
//   Unicode data SQL Server uses the version-0 Windows Latin1_General table;
//   for non-Unicode (varchar) data it uses SQL sort order 52/51, which differs
//   from the Windows table mainly by *not* using "word sort" (hyphen and
//   apostrophe compare as ordinary punctuation).
// - `Latin1_General[_100|_140]_{CI|CS}_{AS|AI}[_KS][_WS][_SC]`: Windows
//   collations, table version 0 (no number), 100 or 140 (treated as 100).
// - `Latin1_General[_100]_BIN` and `_BIN2`: binary (code unit) order.
//
// The linguistic comparison itself is an approximation; see
// `collation_compare.mbt` for exactly what is and is not modelled.

///|
/// How a collation orders strings.
pub(all) enum CollationKind {
  /// Linguistic (Windows / SQL) comparison with case/accent/kana/width flags.
  Linguistic
  /// `_BIN`: first character by code unit, the rest byte-wise (UTF-16LE).
  Bin
  /// `_BIN2`: UTF-16 code unit order.
  Bin2
} derive(Debug, Eq)

///|
/// A collation: name plus the comparison properties bitsql implements.
pub(all) struct Collation {
  /// Canonical name as SQL Server reports it.
  name : String
  kind : CollationKind
  case_sensitive : Bool
  accent_sensitive : Bool
  kana_sensitive : Bool
  width_sensitive : Bool
  /// Sort table version: 0 (SQL_* and unversioned Latin1_General) or 100.
  version : Int
  /// `SQL_` legacy collation (affects non-Unicode comparison).
  sql_collation : Bool
  /// Code page of char/varchar data: 1252, or 65001 for `_UTF8`
  /// collations.
  code_page : Int
} derive(Debug, Eq)

///|
/// `SQL_Latin1_General_CP1_CI_AS`, SQL Server's default server collation.
pub let sql_latin1_general_cp1_ci_as : Collation = {
  name: "SQL_Latin1_General_CP1_CI_AS",
  kind: Linguistic,
  case_sensitive: false,
  accent_sensitive: true,
  kana_sensitive: false,
  width_sensitive: false,
  version: 0,
  sql_collation: true,
  code_page: 1252,
}

///|
/// `Latin1_General_CI_AS`.
pub let latin1_general_ci_as : Collation = Collation::parse(
  "Latin1_General_CI_AS",
).unwrap()

///|
/// `Latin1_General_100_CI_AS`.
pub let latin1_general_100_ci_as : Collation = Collation::parse(
  "Latin1_General_100_CI_AS",
).unwrap()

///|
/// `Latin1_General_100_BIN2`.
pub let latin1_general_100_bin2 : Collation = Collation::parse(
  "Latin1_General_100_BIN2",
).unwrap()

///|
/// The collation bitsql assumes for databases and literals by default.
pub let default_collation : Collation = sql_latin1_general_cp1_ci_as

///|
/// Parse a collation name (case-insensitive, as SQL Server accepts it).
/// Returns None for names bitsql does not model.
pub fn Collation::parse(name : String) -> Collation? {
  let parts = name.split("_").map(fn(p) { p.to_owned().to_upper() }).collect()
  let n = parts.length()
  if n >= 6 &&
    parts[0] == "SQL" &&
    parts[1] == "LATIN1" &&
    parts[2] == "GENERAL" &&
    parts[3] == "CP1" {
    if n != 6 {
      return None
    }
    let cs = match parts[4] {
      "CI" => false
      "CS" => true
      _ => return None
    }
    let as_ = match parts[5] {
      "AS" => true
      "AI" => false
      _ => return None
    }
    return Some({
      name: "SQL_Latin1_General_CP1_\{parts[4]}_\{parts[5]}",
      kind: Linguistic,
      case_sensitive: cs,
      accent_sensitive: as_,
      kana_sensitive: false,
      width_sensitive: false,
      version: 0,
      sql_collation: true,
      code_page: 1252,
    })
  }
  guard n >= 3 && parts[0] == "LATIN1" && parts[1] == "GENERAL" else {
    return None
  }
  let mut i = 2
  let mut version = 0
  let mut version_text = ""
  if parts[i] == "100" || parts[i] == "140" {
    version = 100
    version_text = "_" + parts[i]
    i += 1
  }
  guard i < n else { return None }
  let prefix = "Latin1_General" + version_text
  if parts[i] == "BIN" || parts[i] == "BIN2" {
    // `_BIN2_UTF8` (version 100 only): varchar stored as UTF-8
    let utf8 = i + 2 == n &&
      parts[i] == "BIN2" &&
      parts[i + 1] == "UTF8" &&
      version == 100
    guard i + 1 == n || utf8 else { return None }
    let bin2 = parts[i] == "BIN2"
    return Some({
      name: prefix + "_" + parts[i] + (if utf8 { "_UTF8" } else { "" }),
      kind: if bin2 {
        Bin2
      } else {
        Bin
      },
      case_sensitive: true,
      accent_sensitive: true,
      kana_sensitive: true,
      width_sensitive: true,
      version,
      sql_collation: false,
      code_page: if utf8 {
        65001
      } else {
        1252
      },
    })
  }
  guard i + 1 < n else { return None }
  let cs = match parts[i] {
    "CI" => false
    "CS" => true
    _ => return None
  }
  let as_ = match parts[i + 1] {
    "AS" => true
    "AI" => false
    _ => return None
  }
  let mut ks = false
  let mut ws = false
  let mut sc = false
  let mut utf8 = false
  let mut suffix = ""
  for j in (i + 2)..<n {
    match parts[j] {
      // `_SC_UTF8` (captured: Latin1_General_100_CI_AS_UTF8 without _SC is
      // 448 Invalid collation): varchar stored as UTF-8
      "UTF8" if sc && j == n - 1 => {
        utf8 = true
        suffix = suffix + "_UTF8"
      }
      "KS" if !ks && !ws => {
        ks = true
        suffix = suffix + "_KS"
      }
      "WS" if !ws => {
        ws = true
        suffix = suffix + "_WS"
      }
      // Supplementary-character awareness only changes built-in function
      // behaviour, not the comparison bitsql models (sorting of surrogate
      // pairs as code points is approximated by code units).
      "SC" if version == 100 && !sc => {
        sc = true
        suffix = suffix + "_SC"
      }
      _ => return None
    }
  }
  Some({
    name: prefix + "_" + parts[i] + "_" + parts[i + 1] + suffix,
    kind: Linguistic,
    case_sensitive: cs,
    accent_sensitive: as_,
    kana_sensitive: ks,
    width_sensitive: ws,
    version,
    sql_collation: false,
    code_page: if utf8 {
      65001
    } else {
      1252
    },
  })
}

///|
/// A supplementary-character (`_SC`) collation: string functions count a
/// surrogate pair as one character.
pub fn Collation::supplementary(self : Collation) -> Bool {
  self.name.contains("_SC")
}

///|
/// The error for a COLLATE name bitsql cannot resolve: 448 "Invalid
/// collation", except for real SQL Server collations it does not model
/// (UTF-8 varchar collations, `…_UTF8`), which are an explicit emulator
/// error (EMU_COLLATION_NOT_SUPPORTED).
pub fn unknown_collation_error(name : String) -> SqlError {
  let u = name.to_upper()
  // every valid Latin1_General / SQL_Latin1 UTF-8 collation parses
  // (captured: Latin1_General_100_CI_AS_UTF8 is 448)
  if u.has_suffix("_UTF8") &&
    !u.has_prefix("LATIN1_GENERAL") &&
    !u.has_prefix("SQL_LATIN1_GENERAL") {
    not_supported("collation \{name}", number=EMU_COLLATION_NOT_SUPPORTED)
  } else {
    sql_error(448, "Invalid collation '\{name}'.")
  }
}
