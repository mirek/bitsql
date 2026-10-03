///|
pub(all) enum Step {
  Key(String)
  Index(Int)
} derive(Debug, Eq)

///|
pub(all) struct Path {
  strict : Bool
  steps : Array[Step]
} derive(Debug, Eq)

///|
/// Parses `[lax|strict] $ (.key | ."quoted" | [n])*`. Wildcards and other
/// SQL Server 2025 advanced accessors are reported as unsupported by the
/// caller (see `has_wildcard`). `state` is the 13607 state to report.
pub fn parse_path(path : String, state? : Int = 14) -> Path raise JsonError {
  let n = path.length()
  let mut pos = 0
  fn at(i : Int) -> Int {
    if i < n {
      path.code_unit_at(i).to_int()
    } else {
      -1
    }
  }

  fn fail(i : Int) -> JsonError {
    JsonError(13607, state, unexpected("path", path, i))
  }

  while at(pos) == 0x20 {
    pos += 1
  }
  let mut strict = false
  if path[pos:].has_prefix("strict") {
    strict = true
    pos += 6
  } else if path[pos:].has_prefix("lax") {
    pos += 3
  }
  while at(pos) == 0x20 {
    pos += 1
  }
  if at(pos) != 0x24 {
    raise fail(pos)
  }
  pos += 1
  let steps = []
  while pos < n {
    match at(pos) {
      0x2E => {
        pos += 1
        if at(pos) == 0x22 {
          let s : Scanner = { text: path, pos, doc_state: state, }
          let key = s.string_value() catch { _ => raise fail(s.pos) }
          pos = s.pos
          steps.push(Key(key))
        } else {
          let start = pos
          while pos < n && !(at(pos) is (0x2E | 0x5B | 0x20)) {
            pos += 1
          }
          if pos == start {
            raise fail(pos)
          }
          steps.push(Key(path.unsafe_substring(start~, end=pos)))
        }
      }
      0x5B => {
        pos += 1
        let start = pos
        while at(pos) is (0x30..=0x39) {
          pos += 1
        }
        if pos == start || at(pos) != 0x5D {
          raise fail(pos)
        }
        let digits = path.unsafe_substring(start~, end=pos)
        let mut v = 0
        for c in digits {
          v = v * 10 + (c.to_int() - 0x30)
        }
        steps.push(Index(v))
        pos += 1
      }
      _ => raise fail(pos)
    }
  }
  { strict, steps, }
}
