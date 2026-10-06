///|
fn ascii_word(c : Int) -> Bool {
  (c >= 65 && c <= 90) ||
  (c >= 97 && c <= 122) ||
  (c >= 48 && c <= 57) ||
  c == 95
}

///|
fn assertion(kind : Int, text : Bytes, pos : Int) -> Bool {
  let before = if pos == 0 { -1 } else { text[pos - 1].to_int() }
  let after = if pos == text.length() { -1 } else { text[pos].to_int() }
  match kind {
    0 => pos == 0
    1 => pos == text.length()
    2 => pos == 0 || before == 10
    3 => pos == text.length() || after == 10
    4 => ascii_word(before) != ascii_word(after)
    _ => ascii_word(before) == ascii_word(after)
  }
}

///|
/// Decode a scalar at a UTF-8 byte boundary. Byte atoms can also begin inside
/// a scalar, but rune atoms cannot. Inputs originate from UTF-8 encoding.
fn rune_at(text : Bytes, pos : Int) -> (Int, Int)? {
  if pos >= text.length() {
    return None
  }
  let first = text[pos].to_int()
  if first < 128 {
    return Some((first, 1))
  }
  let count = if first >= 0xF0 {
    4
  } else if first >= 0xE0 {
    3
  } else if first >= 0xC0 {
    2
  } else {
    return None
  }
  if pos + count > text.length() {
    return None
  }
  let mut scalar = first & ((1 << (7 - count)) - 1)
  for i in 1..<count {
    let part = text[pos + i].to_int()
    if part < 128 || part >= 192 {
      return None
    }
    scalar = (scalar << 6) | (part & 63)
  }
  Some((scalar, count))
}

///|
fn in_ranges(value : Int, ranges : Array[(Int, Int)]) -> Bool {
  ranges.iter().any(r => value >= r.0 && value <= r.1)
}

///|
fn rune_matches(
  value : Int,
  ranges : Array[(Int, Int)],
  negate : Bool,
  fold : Bool,
) -> Bool {
  let mut matches = in_ranges(value, ranges)
  if fold {
    let mut other = unicode_fold(value)
    while other != value {
      matches = matches || in_ranges(other, ranges)
      other = unicode_fold(other)
    }
  }
  matches != negate
}

///|
/// Leftmost-first ordered VM with memoized (instruction, byte position)
/// states. RE2 disallows backreferences, so future acceptance does not depend
/// on capture history. Captures use indexed persistent logs, avoiding copies
/// at forks and recursive destruction of long capture histories.
pub fn Program::find(
  self : Program,
  text : Bytes,
  start : Int,
  charge : (Int64) -> Unit raise @types.SqlError,
) -> Match? raise @types.SqlError {
  if start < 0 || start > text.length() {
    return None
  }
  let seen : Set[Int64] = Set([])
  let log : Array[(Int, Int, Int)] = []
  for begin in start..<(text.length() + 1) {
    let stack : Array[(Int, Int, Int)] = [(self.entry, begin, -1)]
    while !stack.is_empty() {
      let (pc, pos, saves) = stack.pop().unwrap()
      let key = (pc.to_int64() << 32) | pos.to_int64()
      if seen.contains(key) {
        continue
      }
      if seen.length() >= 1_000_000 {
        raise @types.emulator_error(
          @types.EMU_WORK_BUDGET,
          "regular expression matching exceeded the state budget",
        )
      }
      seen.add(key)
      charge(1L)
      match self.code[pc] {
        Accept => {
          let slots = Array::make(self.groups * 2, -1)
          let mut history = saves
          while history >= 0 {
            let (slot, at, rest) = log[history]
            if slots[slot] < 0 {
              slots[slot] = at
            }
            history = rest
          }
          let groups = Array::makei(self.groups, i => {
            if slots[2 * i] < 0 || slots[2 * i + 1] < 0 {
              None
            } else {
              Some((slots[2 * i], slots[2 * i + 1]))
            }
          })
          return Some({ groups, })
        }
        Split(first, second) => {
          stack.push((second, pos, saves))
          stack.push((first, pos, saves))
        }
        Save(slot, next) => {
          let head = log.length()
          log.push((slot, pos, saves))
          stack.push((next, pos, head))
        }
        Assert(kind, next) =>
          if assertion(kind, text, pos) {
            stack.push((next, pos, saves))
          }
        ByteAny(next) =>
          if pos < text.length() {
            stack.push((next, pos + 1, saves))
          }
        Rune(ranges, negate, fold, next) =>
          if rune_at(text, pos) is Some((value, count)) &&
            rune_matches(value, ranges, negate, fold) {
            stack.push((next, pos + count, saves))
          }
      }
    }
  }
  None
}

///|
/// Advance after an empty match without splitting a UTF-8 scalar. The
/// terminal boundary advances past the input so iteration terminates.
pub fn next_boundary(text : Bytes, pos : Int) -> Int {
  match rune_at(text, pos) {
    Some((_, length)) => pos + length
    None => pos + 1
  }
}

///|
/// Expand simple-fold equivalence before complementing a nested class.
fn fold_ranges(ranges : Array[(Int, Int)]) -> Array[(Int, Int)] {
  let out = ranges.copy()
  for (a, b, _) in unicode_fold_ranges {
    for value in a..<=b {
      let mut matches = in_ranges(value, ranges)
      let mut other = unicode_fold(value)
      while other != value {
        matches = matches || in_ranges(other, ranges)
        other = unicode_fold(other)
      }
      if matches {
        out.push((value, value))
      }
    }
  }
  out.sort_by((a, b) => a.0.compare(b.0))
  let merged : Array[(Int, Int)] = []
  for (a, b) in out {
    let last = merged.length() - 1
    if last >= 0 && a <= merged[last].1 + 1 {
      let old = merged[last]
      merged[last] = (old.0, if b > old.1 { b } else { old.1 })
    } else {
      merged.push((a, b))
    }
  }
  merged
}
