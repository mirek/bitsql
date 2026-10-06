// LIKE and PATINDEX pattern matching (captured: msduck like-patterns,
// charindex-patindex):
//
// - `%`, `_`, `[set]`, `[^set]`, ranges `[a-c]` with `-` literal first or
//   last; `_` is one UTF-16 code unit (N'🦆' LIKE N'_' is false) except
//   under `_SC` collations, where a surrogate pair is one character
//   (PATINDEX(N'_b', 😀b) is 1) and positions count characters;
// - characters and ranges compare under the collation: CI matches 'B' to
//   `[a-c]`, CI_AS does not match 'É' to `[e]`, CI_AI does, BIN2 compares
//   code units, and a SQL_..._CS collation on varchar orders aAbBcC so
//   `[a-c]` matches 'B';
// - code units a linguistic collation ignores (surrogates in version-0
//   tables, NUL, soft hyphen) take no part in the match: PATINDEX of
//   N'%😀%' in N'a😀' is 1, of N'_b' in N'😀b' is 0, of N'%b%' in N'😀b' 3;
// - `[]` matches nothing, an unclosed `[` never matches, a reversed range
//   matches nothing, an escape character at the end of the pattern never
//   matches;
// - trailing blanks of the value are ignored only when both operands are
//   non-Unicode ('a ' LIKE 'a' is true, N'a ' LIKE N'a' false).

///|
fn like_ascii_letter(c : Int) -> Bool {
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int())
}

///|
fn like_unit_string(c : Int) -> String {
  if c >= 0x10000 {
    let v = c - 0x10000
    let sb = StringBuilder()
    sb.write_char((0xD800 + (v >> 10)).unsafe_to_char())
    sb.write_char((0xDC00 + (v & 0x3FF)).unsafe_to_char())
    sb.to_string()
  } else {
    c.unsafe_to_char().to_string()
  }
}

///|
/// Character equality under the collation.
fn like_char_eq(a : Int, b : Int, coll : @types.Collation, ansi : Bool) -> Bool {
  if a == b {
    return true
  }
  if !(coll.kind is Linguistic) {
    return false
  }
  if !coll.turkish() && a < 0x80 && b < 0x80 {
    // ASCII: only letters differ by case
    return !coll.case_sensitive &&
      like_ascii_letter(a) &&
      like_ascii_letter(b) &&
      (a | 0x20) == (b | 0x20)
  }
  @types.compare_strings(like_unit_string(a), like_unit_string(b), coll, ansi~) ==
  0
}

///|
/// Character order under the collation (ranges).
fn like_char_cmp(a : Int, b : Int, coll : @types.Collation, ansi : Bool) -> Int {
  if a == b {
    return 0
  }
  match coll.kind {
    Bin2 | Bin if !ansi => if a < b { -1 } else { 1 }
    _ =>
      @types.compare_strings(
        like_unit_string(a),
        like_unit_string(b),
        coll,
        ansi~,
      )
  }
}

///|
/// The characters of a string as LIKE sees them, with each one's 1-based
/// position (code units, or characters under `_SC`). Ignorable units are
/// dropped when `drop_ignorable`.
fn like_units(
  s : String,
  coll : @types.Collation,
  drop_ignorable : Bool,
) -> (Array[Int], Array[Int]) {
  let units = []
  let pos = []
  let sc = coll.supplementary()
  let mut i = 0
  let mut p = 1
  while i < s.length() {
    let u = s.code_unit_at(i).to_int()
    let (c, w) = if sc &&
      u >= 0xD800 &&
      u <= 0xDBFF &&
      i + 1 < s.length() &&
      s.code_unit_at(i + 1).to_int() >= 0xDC00 &&
      s.code_unit_at(i + 1).to_int() <= 0xDFFF {
      let lo = s.code_unit_at(i + 1).to_int()
      (0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00), 2)
    } else {
      (u, 1)
    }
    if !(drop_ignorable && @types.collation_ignores(c, coll)) {
      units.push(c)
      pos.push(p)
    }
    i += w
    p += 1
  }
  (units, pos)
}

///|
/// Does `s` match pattern `p`? `ansi`: both operands are non-Unicode.
pub fn like_match(
  s : String,
  p : String,
  esc : Int?,
  coll : @types.Collation,
  ansi : Bool,
) -> Bool {
  let (pu, _) = like_units(p, coll, true)
  let (su, _) = like_units(s, coll, true)
  like_from(su, 0, pu, esc, coll, ansi)
}

///|
/// Match of `su[from..]` (with the ANSI trailing-blank rule).
fn like_from(
  su : Array[Int],
  from : Int,
  pu : Array[Int],
  esc : Int?,
  coll : @types.Collation,
  ansi : Bool,
) -> Bool {
  if like_exact(su, from, su.length(), pu, esc, coll, ansi) {
    return true
  }
  let mut n = su.length()
  while n > from && su[n - 1] == ' '.to_int() {
    n -= 1
  }
  ansi && n < su.length() && like_exact(su, from, n, pu, esc, coll, ansi)
}

///|
fn like_exact(
  su : Array[Int],
  from : Int,
  end : Int,
  pu : Array[Int],
  esc : Int?,
  coll : @types.Collation,
  ansi : Bool,
) -> Bool {
  let sl = end - from
  let pl = pu.length()
  let s = (k : Int) => su[from + k]
  // memo[i][j]: does s[i..] match p[j..] (0 unknown, 1 yes, 2 no)
  let memo = FixedArray::make((sl + 1) * (pl + 1), 0)
  fn go(i : Int, j : Int) -> Bool {
    let key = i * (pl + 1) + j
    if memo[key] != 0 {
      return memo[key] == 1
    }
    let r = if j == pl {
      i == sl
    } else {
      let c = pu[j]
      if esc is Some(e) && c == e {
        // a trailing escape character never matches
        j + 1 < pl &&
        i < sl &&
        like_char_eq(s(i), pu[j + 1], coll, ansi) &&
        go(i + 1, j + 2)
      } else if c == '%'.to_int() {
        go(i, j + 1) || (i < sl && go(i + 1, j))
      } else if c == '_'.to_int() {
        i < sl && go(i + 1, j + 1)
      } else if c == '['.to_int() {
        let mut k = j + 1
        let negate = k < pl && pu[k] == '^'.to_int()
        if negate {
          k += 1
        }
        let start = k
        while k < pl && pu[k] != ']'.to_int() {
          k += 1
        }
        if k >= pl || i >= sl {
          // an unclosed `[` never matches
          false
        } else {
          let ch = s(i)
          let mut hit = false
          let mut m = start
          while m < k {
            let lo = pu[m]
            if m + 2 < k && pu[m + 1] == '-'.to_int() {
              let hi = pu[m + 2]
              if like_char_cmp(lo, ch, coll, ansi) <= 0 &&
                like_char_cmp(ch, hi, coll, ansi) <= 0 {
                hit = true
              }
              m += 3
            } else {
              if like_char_eq(ch, lo, coll, ansi) {
                hit = true
              }
              m += 1
            }
          }
          // `[]` (start == k) matches nothing, also negated
          start < k && hit != negate && go(i + 1, k + 1)
        }
      } else {
        i < sl && like_char_eq(s(i), c, coll, ansi) && go(i + 1, j + 1)
      }
    }
    memo[key] = if r { 1 } else { 2 }
    r
  }

  go(0, 0)
}

///|
/// PATINDEX: 1-based start of the first match of the pattern after its
/// leading `%` signs, 0 if none (captured: PATINDEX('%', 'abc') is 1).
fn patindex(
  p : String,
  s : String,
  coll : @types.Collation,
  ansi : Bool,
) -> Int {
  let (pu, _) = like_units(p, coll, true)
  let (su, pos) = like_units(s, coll, true)
  let mut lead = 0
  while lead < pu.length() && pu[lead] == '%'.to_int() {
    lead += 1
  }
  if lead == 0 {
    return if like_from(su, 0, pu, None, coll, ansi) { 1 } else { 0 }
  }
  let rest = pu[lead:].to_owned()
  if rest.length() == 0 {
    return 1
  }
  for i in 0..<=su.length() {
    if like_from(su, i, rest, None, coll, ansi) {
      return if i < pos.length() { pos[i] } else { 1 }
    }
  }
  0
}
