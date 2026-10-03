// String comparison under a collation.
//
// What is modelled (and checked against the 140 captured comparisons in
// msduck reference/unicode-collation.json):
//
// - Pad semantics: trailing U+0020 never matters. BIN2 compares UTF-16
//   code units with the shorter operand space-padded (so 'a' > 'a' + NUL,
//   captured); linguistic collations ignore trailing spaces.
// - BIN2: code unit order (a surrogate pair sorts by its high surrogate,
//   below U+E000). BIN: first unit, then UTF-16LE bytes.
// - Linguistic (Windows / SQL collations on Unicode data):
//   * NUL (U+0000) is ignorable; with the version-0 tables
//     (SQL_Latin1_General_CP1_*, Latin1_General_* without _100) surrogate
//     code units and U+FFFD are ignorable too (captured: all surrogates
//     compare equal to each other and to U+FFFD); version 100 sorts
//     surrogates after all BMP characters.
//   * case: ASCII, Latin-1, Latin Extended-A, Greek and basic Cyrillic case
//     pairs; lower case sorts first in CS collations ('a' < 'A', σ/ς < Σ).
//   * accents: Latin-1 and Latin Extended-A letters decompose into base
//     letter + combining mark, so 'é' = 'e' + U+0301 (captured), and
//     U+0300–U+036F combining marks are accent-only weights; unaccented
//     sorts first ('a' < 'á').
//   * expansions ß = ss, æ = ae, œ = oe, ĳ = ij (captured for ß, æ, œ).
//   * İ is i + dot accent, ı a separate letter after i (captured: İ > i,
//     ı > I under CI).
//   * width: fullwidth ASCII equals ASCII unless _WS; kana: katakana equals
//     hiragana unless _KS (captured).
//   * "word sort": hyphen and apostrophe have no primary weight and only
//     break ties (so 'ab' < 'a-c'); SQL_ collations on non-Unicode (varchar)
//     data use string sort instead, where they are ordinary punctuation.
//
// Approximations (documented in docs/design/fidelity-traps.md):
// - primary order of non-letters is by code point (controls < space <
//   punctuation/symbols by code point < digits < Latin letters < other
//   scripts by code point); real Windows tables order punctuation and
//   symbols differently and give many symbols ignorable weights;
// - non-Latin scripts get code-point primaries (no linguistic order, no
//   accents), CJK/Hangul/Indic are not modelled;
// - SQL sort order 52 for varchar under SQL_ collations is approximated by
//   the same weights minus word sort and expansions.

///|
/// Compare two strings under a collation: -1, 0 or 1. `ansi` marks
/// non-Unicode (char/varchar) operands, which only matters for SQL_
/// collations.
pub fn compare_strings(
  a : String,
  b : String,
  collation : Collation,
  ansi? : Bool = false,
) -> Int {
  match collation.kind {
    Bin2 => compare_bin2(a, b)
    Bin => compare_bin(a, b)
    Linguistic => compare_linguistic(a, b, collation, ansi)
  }
}

///|
fn sign_of(x : Int) -> Int {
  if x < 0 {
    -1
  } else if x > 0 {
    1
  } else {
    0
  }
}

///|
fn compare_bin2(a : String, b : String) -> Int {
  let n = if a.length() > b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = if i < a.length() { a[i].to_int() } else { 0x20 }
    let y = if i < b.length() { b[i].to_int() } else { 0x20 }
    if x != y {
      return sign_of(x - y)
    }
  }
  0
}

///|
fn compare_bin(a : String, b : String) -> Int {
  // first character as a code unit, the rest byte by byte (UTF-16LE)
  let ua = if a.length() > 0 { a[0].to_int() } else { 0x20 }
  let ub = if b.length() > 0 { b[0].to_int() } else { 0x20 }
  if ua != ub {
    return sign_of(ua - ub)
  }
  let n = if a.length() > b.length() { a.length() } else { b.length() }
  for i in 1..<n {
    let x = if i < a.length() { a[i].to_int() } else { 0x20 }
    let y = if i < b.length() { b[i].to_int() } else { 0x20 }
    let lx = x % 256
    let ly = y % 256
    if lx != ly {
      return sign_of(lx - ly)
    }
    if x / 256 != y / 256 {
      return sign_of(x / 256 - y / 256)
    }
  }
  0
}

///|
/// One collation element.
priv struct Element {
  primary : Int // 0 = accent-only element
  secondary : Int // accent (combining mark code point), 0 = none
  tertiary : Int // 0 lower / uncased, 1 variant (final sigma), 2 upper
  kana : Int // 1 = katakana form of a hiragana primary
  width : Int // 1 = fullwidth form
}

///|
/// Latin Extended-A (U+0100..U+017F) lowercase letters: base letter and
/// combining mark. 0 mark = own letter (see `latin_ext_primary`).
let latin_ext_a : Array[(Int, Int, Int)] = [
  (0x101, 'a', 0x304),
  (0x103, 'a', 0x306),
  (0x105, 'a', 0x328),
  (0x107, 'c', 0x301),
  (0x109, 'c', 0x302),
  (0x10B, 'c', 0x307),
  (0x10D, 'c', 0x30C),
  (0x10F, 'd', 0x30C),
  (0x111, 'd', 0x335),
  (0x113, 'e', 0x304),
  (0x115, 'e', 0x306),
  (0x117, 'e', 0x307),
  (0x119, 'e', 0x328),
  (0x11B, 'e', 0x30C),
  (0x11D, 'g', 0x302),
  (0x11F, 'g', 0x306),
  (0x121, 'g', 0x307),
  (0x123, 'g', 0x327),
  (0x125, 'h', 0x302),
  (0x127, 'h', 0x335),
  (0x129, 'i', 0x303),
  (0x12B, 'i', 0x304),
  (0x12D, 'i', 0x306),
  (0x12F, 'i', 0x328),
  (0x135, 'j', 0x302),
  (0x137, 'k', 0x327),
  (0x13A, 'l', 0x301),
  (0x13C, 'l', 0x327),
  (0x13E, 'l', 0x30C),
  (0x140, 'l', 0x307),
  (0x142, 'l', 0x337),
  (0x144, 'n', 0x301),
  (0x146, 'n', 0x327),
  (0x148, 'n', 0x30C),
  (0x14D, 'o', 0x304),
  (0x14F, 'o', 0x306),
  (0x151, 'o', 0x30B),
  (0x155, 'r', 0x301),
  (0x157, 'r', 0x327),
  (0x159, 'r', 0x30C),
  (0x15B, 's', 0x301),
  (0x15D, 's', 0x302),
  (0x15F, 's', 0x327),
  (0x161, 's', 0x30C),
  (0x163, 't', 0x327),
  (0x165, 't', 0x30C),
  (0x167, 't', 0x335),
  (0x169, 'u', 0x303),
  (0x16B, 'u', 0x304),
  (0x16D, 'u', 0x306),
  (0x16F, 'u', 0x30A),
  (0x171, 'u', 0x30B),
  (0x173, 'u', 0x328),
  (0x175, 'w', 0x302),
  (0x177, 'y', 0x302),
  (0x17A, 'z', 0x301),
  (0x17C, 'z', 0x307),
  (0x17E, 'z', 0x30C),
]

///|
/// Latin-1 lowercase letters U+00E0..U+00FF: (base, mark); base 0 = special.
let latin1_lower : FixedArray[(Int, Int)] = [
  ('a', 0x300),
  ('a', 0x301),
  ('a', 0x302),
  ('a', 0x303),
  ('a', 0x308),
  ('a', 0x30A),
  (0, 0), // æ
  ('c', 0x327),
  ('e', 0x300),
  ('e', 0x301),
  ('e', 0x302),
  ('e', 0x308),
  ('i', 0x300),
  ('i', 0x301),
  ('i', 0x302),
  ('i', 0x308),
  ('d', 0x335), // ð
  ('n', 0x303),
  ('o', 0x300),
  ('o', 0x301),
  ('o', 0x302),
  ('o', 0x303),
  ('o', 0x308),
  (0, 0), // ÷
  ('o', 0x338), // ø
  ('u', 0x300),
  ('u', 0x301),
  ('u', 0x302),
  ('u', 0x308),
  ('y', 0x301),
  (0, 0), // þ
  ('y', 0x308),
]

///|
/// Lowercase a code unit; returns (lower, is_upper).
fn fold_case(u : Int) -> (Int, Bool) {
  if u >= 'A' && u <= 'Z' {
    (u + 32, true)
  } else if u >= 0xC0 && u <= 0xDE && u != 0xD7 {
    (u + 32, true)
  } else if u == 0x178 {
    (0xFF, true)
  } else if u == 0x130 {
    (0x130, true) // İ handled by the caller
  } else if u >= 0x100 && u <= 0x137 && u != 0x131 {
    if u % 2 == 0 {
      (u + 1, true)
    } else {
      (u, false)
    }
  } else if u >= 0x139 && u <= 0x148 {
    if u % 2 == 1 {
      (u + 1, true)
    } else {
      (u, false)
    }
  } else if u >= 0x14A && u <= 0x177 {
    if u % 2 == 0 {
      (u + 1, true)
    } else {
      (u, false)
    }
  } else if u >= 0x179 && u <= 0x17E {
    if u % 2 == 1 {
      (u + 1, true)
    } else {
      (u, false)
    }
  } else if u >= 0x391 && u <= 0x3A9 && u != 0x3A2 {
    (u + 32, true)
  } else if u >= 0x410 && u <= 0x42F {
    (u + 32, true)
  } else if u >= 0x400 && u <= 0x40F {
    (u + 80, true)
  } else {
    (u, false)
  }
}

///|
fn letter_primary(c : Int) -> Int {
  0x10000 + (c - 'a') * 4
}

///|
fn is_ignorable(u : Int, version : Int) -> Bool {
  u == 0 ||
  (version == 0 && ((u >= 0xD800 && u <= 0xDFFF) || u == 0xFFFD)) ||
  u == 0xAD // soft hyphen
}

///|
fn push_letter(
  out : Array[Element],
  base : Int,
  mark : Int,
  upper : Bool,
) -> Unit {
  out.push({
    primary: letter_primary(base),
    secondary: 0,
    tertiary: if upper {
      2
    } else {
      0
    },
    kana: 0,
    width: 0,
  })
  if mark != 0 {
    out.push({ primary: 0, secondary: mark, tertiary: 0, kana: 0, width: 0, })
  }
}

///|
/// Elements of a string plus the word-sort ignorables (position, unit).
fn collation_elements(
  s : String,
  collation : Collation,
  ansi : Bool,
) -> (Array[Element], Array[(Int, Int)]) {
  let version = collation.version
  let word_sort = !(ansi && collation.sql_collation)
  // pad semantics: drop trailing spaces (and trailing ignorables)
  let mut n = s.length()
  while n > 0 && (s[n - 1] == ' ' || is_ignorable(s[n - 1].to_int(), version)) {
    n -= 1
  }
  let out : Array[Element] = []
  let ws : Array[(Int, Int)] = []
  for i in 0..<n {
    let raw = s[i].to_int()
    if is_ignorable(raw, version) {
      continue
    }
    if word_sort && (raw == '-' || raw == '\'') {
      ws.push((out.length(), raw))
      continue
    }
    // width: fullwidth ASCII
    let (u0, width) = if raw >= 0xFF01 && raw <= 0xFF5E {
      (raw - 0xFEE0, 1)
    } else {
      (raw, 0)
    }
    // kana: katakana → hiragana
    let (u1, kana) = if u0 >= 0x30A1 && u0 <= 0x30F6 {
      (u0 - 0x60, 1)
    } else {
      (u0, 0)
    }
    if u1 >= 0x300 && u1 <= 0x36F {
      out.push({ primary: 0, secondary: u1, tertiary: 0, kana: 0, width: 0, })
      continue
    }
    let (u, upper) = fold_case(u1)
    let start = out.length()
    if u >= 'a' && u <= 'z' {
      push_letter(out, u, 0, upper)
    } else if u >= '0' && u <= '9' {
      out.push({
        primary: 0x8000 + u,
        secondary: 0,
        tertiary: 0,
        kana: 0,
        width: 0,
      })
    } else if u == 0xB9 || u == 0xB2 || u == 0xB3 {
      let digit : Int = if u == 0xB9 {
        '1'
      } else if u == 0xB2 {
        '2'
      } else {
        '3'
      }
      out.push({
        primary: 0x8000 + digit,
        secondary: 0,
        tertiary: 1,
        kana: 0,
        width: 0,
      })
    } else if u == 0xDF {
      // ß → ss
      push_letter(out, 's', 0, false)
      push_letter(out, 's', 0, false)
    } else if u == 0xE6 && word_sort {
      push_letter(out, 'a', 0, upper)
      push_letter(out, 'e', 0, upper)
    } else if u == 0x153 && word_sort {
      push_letter(out, 'o', 0, upper)
      push_letter(out, 'e', 0, upper)
    } else if u == 0x133 && word_sort {
      push_letter(out, 'i', 0, upper)
      push_letter(out, 'j', 0, upper)
    } else if u == 0xE6 || u == 0x153 || u == 0x133 {
      // string sort: own letters right after a / o / i
      let base : Int = if u == 0xE6 {
        'a'
      } else if u == 0x153 {
        'o'
      } else {
        'i'
      }
      out.push({
        primary: letter_primary(base) + 2,
        secondary: 0,
        tertiary: if upper {
          2
        } else {
          0
        },
        kana: 0,
        width: 0,
      })
    } else if u >= 0xE0 && u <= 0xFF && latin1_lower[u - 0xE0].0 != 0 {
      let (base, mark) = latin1_lower[u - 0xE0]
      push_letter(out, base, mark, upper)
    } else if u == 0xFE {
      // þ after z
      out.push({
        primary: letter_primary('z') + 4,
        secondary: 0,
        tertiary: if upper {
          2
        } else {
          0
        },
        kana: 0,
        width: 0,
      })
    } else if u == 0x130 {
      // İ = I + dot above
      push_letter(out, 'i', 0x307, true)
    } else if u == 0x131 {
      // ı: own letter right after i
      out.push({
        primary: letter_primary('i') + 1,
        secondary: 0,
        tertiary: 0,
        kana: 0,
        width: 0,
      })
    } else if u >= 0x100 && u <= 0x17F {
      let mut found = false
      for e in latin_ext_a {
        if e.0 == u {
          push_letter(out, e.1, e.2, upper)
          found = true
          break
        }
      }
      if !found {
        out.push({
          primary: 0x20000 + u,
          secondary: 0,
          tertiary: if upper {
            2
          } else {
            0
          },
          kana: 0,
          width: 0,
        })
      }
    } else if u == 0x3C2 {
      // final sigma: σ with a tertiary variant
      out.push({
        primary: 0x20000 + 0x3C3,
        secondary: 0,
        tertiary: 1,
        kana: 0,
        width: 0,
      })
    } else if u >= 0xD800 && u <= 0xDFFF {
      out.push({
        primary: 0x40000 + u,
        secondary: 0,
        tertiary: 0,
        kana: 0,
        width: 0,
      })
    } else if u < 0x80 || (u >= 0xA0 && u <= 0xBF) || u == 0xD7 || u == 0xF7 {
      // controls, space, punctuation and symbols
      out.push({
        primary: 0x100 + u,
        secondary: 0,
        tertiary: 0,
        kana: 0,
        width: 0,
      })
    } else {
      out.push({
        primary: 0x20000 + u,
        secondary: 0,
        tertiary: if upper {
          2
        } else {
          0
        },
        kana: 0,
        width: 0,
      })
    }
    for j in start..<out.length() {
      if out[j].primary != 0 {
        out[j] = { ..out[j], kana, width, }
      }
    }
  }
  (out, ws)
}

///|
fn compare_level(
  a : Array[Element],
  b : Array[Element],
  key : (Element) -> Int,
  skip_zero_primary : Bool,
) -> Int {
  let xs = if skip_zero_primary { a.filter(e => e.primary != 0) } else { a }
  let ys = if skip_zero_primary { b.filter(e => e.primary != 0) } else { b }
  let n = if xs.length() < ys.length() { xs.length() } else { ys.length() }
  for i in 0..<n {
    let x = key(xs[i])
    let y = key(ys[i])
    if x != y {
      return sign_of(x - y)
    }
  }
  sign_of(xs.length() - ys.length())
}

///|
fn compare_linguistic(
  a : String,
  b : String,
  collation : Collation,
  ansi : Bool,
) -> Int {
  let (ea, wa) = collation_elements(a, collation, ansi)
  let (eb, wb) = collation_elements(b, collation, ansi)
  let primary = compare_level(ea, eb, e => e.primary, true)
  if primary != 0 {
    return primary
  }
  if collation.accent_sensitive {
    let c = compare_level(ea, eb, e => e.secondary, false)
    if c != 0 {
      return c
    }
  }
  if collation.case_sensitive {
    let c = compare_level(ea, eb, e => e.tertiary, true)
    if c != 0 {
      return c
    }
  }
  if collation.kana_sensitive {
    let c = compare_level(ea, eb, e => e.kana, true)
    if c != 0 {
      return c
    }
  }
  if collation.width_sensitive {
    let c = compare_level(ea, eb, e => e.width, true)
    if c != 0 {
      return c
    }
  }
  // word-sort ignorables break remaining ties (an unverified detail: they
  // are compared by position, then code unit)
  let n = if wa.length() < wb.length() { wa.length() } else { wb.length() }
  for i in 0..<n {
    if wa[i].0 != wb[i].0 {
      return sign_of(wb[i].0 - wa[i].0)
    }
    if wa[i].1 != wb[i].1 {
      return sign_of(wa[i].1 - wb[i].1)
    }
  }
  sign_of(wa.length() - wb.length())
}
