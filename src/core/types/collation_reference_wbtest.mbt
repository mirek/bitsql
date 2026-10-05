// Reference implementation for the packed collation code: the original
// element-per-struct version of collation_elements / compare_linguistic /
// text_key, kept verbatim (renamed ref_*) so the allocation-free code in
// collation_compare.mbt and sort_key.mbt can be checked against it
// bit for bit (collation_compare_wbtest.mbt, sort_key_wbtest.mbt).

///|
/// One collation element.
priv struct RefElement {
  primary : Int // 0 = accent-only element
  secondary : Int // accent rank (accent_weight), 0 = none
  tertiary : Int // 0 lower / uncased, 1 variant (final sigma), 2 upper
  kana : Int // 1 = katakana form of a hiragana primary
  width : Int // 1 = fullwidth form
}

///|
/// Lowercase a code unit; returns (lower, is_upper).
fn ref_fold_case(u : Int) -> (Int, Bool) {
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
fn ref_push_letter(
  out : Array[RefElement],
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
fn ref_collation_elements(
  s : String,
  collation : Collation,
  ansi : Bool,
) -> (Array[RefElement], Array[(Int, Int)]) {
  let version = collation.version
  let word_sort = !(ansi && collation.sql_collation)
  // SQL sort orders on varchar data give NUL a weight below the space
  // (captured: MIN over '', ' ' and CHAR(0) is CHAR(0); msduck
  // character-extrema #098, #130)
  let ignored = (u : Int) => is_ignorable(u, version) && !(u == 0 && !word_sort)
  // pad semantics: drop trailing spaces (and trailing ignorables)
  let mut n = s.length()
  while n > 0 && (s[n - 1] == ' ' || ignored(s[n - 1].to_int())) {
    n -= 1
  }
  let out : Array[RefElement] = []
  let ws : Array[(Int, Int)] = []
  for i in 0..<n {
    let raw = s[i].to_int()
    if ignored(raw) {
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
    let (u, upper) = ref_fold_case(u1)
    let start = out.length()
    if u >= 'a' && u <= 'z' {
      ref_push_letter(out, u, 0, upper)
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
    } else if u == 0xDF && word_sort {
      // ß → ss
      ref_push_letter(out, 's', 0, false)
      ref_push_letter(out, 's', 0, false)
    } else if u == 0xDF {
      // string sort (SQL_ collation, varchar): ß sorts after 'ss' and before
      // 'st' but is not equal to 'ss' (captured probe; CHARINDEX('ss',
      // 'straße') is 0, functions/more#054). Modelled as "ss" with an
      // accent-level difference.
      ref_push_letter(out, 's', 0, false)
      ref_push_letter(out, 's', 0x370, false)
    } else if u == 0xE6 && word_sort {
      ref_push_letter(out, 'a', 0, upper)
      ref_push_letter(out, 'e', 0, upper)
    } else if u == 0x153 && word_sort {
      ref_push_letter(out, 'o', 0, upper)
      ref_push_letter(out, 'e', 0, upper)
    } else if u == 0x133 && word_sort {
      ref_push_letter(out, 'i', 0, upper)
      ref_push_letter(out, 'j', 0, upper)
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
      ref_push_letter(out, base, mark, upper)
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
      ref_push_letter(out, 'i', 0x307, true)
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
          ref_push_letter(out, e.1, e.2, upper)
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
  // accents sort in the table's order, not by code point (captured:
  // msduck default-collation weights-accented-letter-order: á < à < ä < ā)
  for k, e in out {
    if e.secondary != 0 {
      out[k] = { ..e, secondary: accent_weight(e.secondary, version), }
    }
  }
  (out, ws)
}

///|
fn ref_compare_level(
  a : Array[RefElement],
  b : Array[RefElement],
  key : (RefElement) -> Int,
  skip_zero_primary : Bool,
) -> Int {
  // walks both arrays, skipping accent-only elements when asked, without
  // building filtered copies
  let mut i = 0
  let mut j = 0
  while true {
    if skip_zero_primary {
      while i < a.length() && a[i].primary == 0 {
        i += 1
      }
      while j < b.length() && b[j].primary == 0 {
        j += 1
      }
    }
    if i >= a.length() || j >= b.length() {
      break
    }
    let x = key(a[i])
    let y = key(b[j])
    if x != y {
      return sign_of(x - y)
    }
    i += 1
    j += 1
  }
  if i < a.length() {
    1
  } else if j < b.length() {
    -1
  } else {
    0
  }
}

///|
fn ref_compare_linguistic(
  a : String,
  b : String,
  collation : Collation,
  ansi : Bool,
) -> Int {
  let (ea, wa) = ref_collation_elements(a, collation, ansi)
  let (eb, wb) = ref_collation_elements(b, collation, ansi)
  let primary = ref_compare_level(ea, eb, e => e.primary, true)
  // pad semantics under SQL sort orders on varchar: the shorter operand
  // is space-padded, so a control character (NUL) after the common prefix
  // sorts below it (captured: MIN('', CHAR(0)) is CHAR(0), msduck
  // character-extrema #098)
  if ansi && collation.sql_collation && primary != 0 {
    let xs = ea.filter(e => e.primary != 0)
    let ys = eb.filter(e => e.primary != 0)
    let n = if xs.length() < ys.length() { xs.length() } else { ys.length() }
    let prefix = (0).until(n).all(i => xs[i].primary == ys[i].primary)
    if prefix && xs.length() != ys.length() {
      let longer_next = if xs.length() > n { xs[n] } else { ys[n] }
      if longer_next.primary < 0x100 + ' '.to_int() {
        return if xs.length() > n { -1 } else { 1 }
      }
    }
  }
  if primary != 0 {
    return primary
  }
  if collation.accent_sensitive {
    let c = ref_compare_level(ea, eb, e => e.secondary, false)
    if c != 0 {
      return c
    }
  }
  if collation.case_sensitive {
    let c = ref_compare_level(ea, eb, e => e.tertiary, true)
    if c != 0 {
      // SQL sort orders on varchar data put upper case first (captured:
      // 'A' < 'a' COLLATE SQL_Latin1_General_CP1_CS_AS, while N'A' > N'a';
      // msduck gaps-conversion#1221)
      return if ansi && collation.sql_collation { -c } else { c }
    }
  }
  if collation.kana_sensitive {
    let c = ref_compare_level(ea, eb, e => e.kana, true)
    if c != 0 {
      return c
    }
  }
  if collation.width_sensitive {
    let c = ref_compare_level(ea, eb, e => e.width, true)
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

///|
/// Linguistic comparison as one integer sequence, compared
/// lexicographically (a proper prefix first). Each level `ref_compare_linguistic`
/// consults, in its order, is written as weight + 1 per element it looks
/// at, then a 0 terminator, so an exhausted level sorts first exactly as
/// `ref_compare_level` returns; the word-sort ignorables follow as (position
/// descending, unit) pairs. None where `compare_strings` takes another
/// route: binary collations (space padding is not a prefix order) and the
/// SQL sort order on varchar data (its NUL padding rule).
fn ref_text_key(
  s : String,
  collation : Collation,
  ansi : Bool,
) -> FixedArray[Int]? {
  let ansi = ansi && !collation.utf8()
  if !(collation.kind is Linguistic) || (ansi && collation.sql_collation) {
    return None
  }
  // no ASCII shortcut: the reference always builds elements
  let (es, ws) = ref_collation_elements(s, collation, ansi)
  let out : Array[Int] = []
  let level = (key : (RefElement) -> Int, skip_zero_primary : Bool) => {
    for e in es {
      if !(skip_zero_primary && e.primary == 0) {
        out.push(key(e) + 1)
      }
    }
    out.push(0)
  }
  level(e => e.primary, true)
  if collation.accent_sensitive {
    level(e => e.secondary, false)
  }
  if collation.case_sensitive {
    level(e => e.tertiary, true)
  }
  if collation.kana_sensitive {
    level(e => e.kana, true)
  }
  if collation.width_sensitive {
    level(e => e.width, true)
  }
  // a later position sorts first (ref_compare_linguistic: sign_of(wb - wa))
  for w in ws {
    out.push(0x3FFFFFFF - w.0)
    out.push(w.1 + 1)
  }
  Some(FixedArray::from_array(out))
}
