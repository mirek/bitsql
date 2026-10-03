///|
/// Splits a client script on `GO` batch separators the way sqlcmd/SSMS do:
/// `GO` alone on a line (case-insensitive, surrounding blanks allowed,
/// optional repeat count, optional trailing `--` comment), never inside a
/// string, quoted identifier or block comment. `GO n` repeats the preceding
/// batch `n` times. Whitespace-only batches are dropped. Never raises:
/// unterminated strings/comments simply run to the end of the script.
pub fn split_go_batches(script : String) -> Array[String] {
  let batches : Array[String] = []
  let n = script.length()
  let mut batch_start = 0
  let mut i = 0
  // state: 0 normal, 1 'string', 2 [ident], 3 "ident", 4 block comment
  let mut state = 0
  let mut depth = 0
  let mut at_line_start = true
  while i <= n {
    if at_line_start && state == 0 {
      at_line_start = false
      match go_line(script, i) {
        Some((count, line_end)) => {
          let text = script
            .view(start_offset=batch_start, end_offset=i)
            .to_owned()
          if text.trim().length() > 0 {
            for _ in 0..<count {
              batches.push(text)
            }
          }
          // Skip the GO line including its newline.
          i = if line_end < n { line_end + 1 } else { n + 1 }
          batch_start = if line_end < n { line_end + 1 } else { n }
          at_line_start = true
          continue
        }
        None => ()
      }
    }
    if i == n {
      break
    }
    let c = script[i].to_int()
    let c1 = if i + 1 < n { script[i + 1].to_int() } else { -1 }
    match state {
      0 =>
        if c == 39 {
          state = 1
        } else if c == 91 {
          state = 2
        } else if c == 34 {
          state = 3
        } else if c == 47 && c1 == 42 {
          state = 4
          depth = 1
          i += 1
        } else if c == 45 && c1 == 45 {
          // Line comment: skip to the newline (not consumed).
          while i + 1 < n && script[i + 1] != '\n' {
            i += 1
          }
        }
      1 => if c == 39 { state = 0 } // '' re-enters on the next quote
      2 => if c == 93 { state = 0 }
      3 => if c == 34 { state = 0 }
      _ =>
        if c == 47 && c1 == 42 {
          depth += 1
          i += 1
        } else if c == 42 && c1 == 47 {
          depth -= 1
          i += 1
          if depth == 0 {
            state = 0
          }
        }
    }
    if c == 10 {
      at_line_start = true
    }
    i += 1
  }
  if batch_start < n {
    let text = script.view(start_offset=batch_start).to_owned()
    if text.trim().length() > 0 {
      batches.push(text)
    }
  }
  batches
}

///|
/// If the line starting at `start` is a GO separator, returns (repeat count,
/// offset of the line's terminating `\n` or end of script).
fn go_line(s : String, start : Int) -> (Int, Int)? {
  let n = s.length()
  let mut i = start
  while i < n && (s[i] == ' ' || s[i] == '\t') {
    i += 1
  }
  if i + 2 > n ||
    !(s[i] == 'g' || s[i] == 'G') ||
    !(s[i + 1] == 'o' || s[i + 1] == 'O') {
    return None
  }
  i += 2
  let after_go = i
  while i < n && (s[i] == ' ' || s[i] == '\t') {
    i += 1
  }
  let mut count = 1
  if i < n && s[i] >= '0' && s[i] <= '9' {
    if i == after_go {
      return None
    }
    count = 0
    while i < n && s[i] >= '0' && s[i] <= '9' {
      count = count * 10 + (s[i].to_int() - 48)
      i += 1
    }
    while i < n && (s[i] == ' ' || s[i] == '\t') {
      i += 1
    }
  }
  if i + 1 < n && s[i] == '-' && s[i + 1] == '-' {
    while i < n && s[i] != '\n' {
      i += 1
    }
  }
  if i < n && s[i] == '\r' {
    i += 1
  }
  if i < n && s[i] != '\n' {
    return None
  }
  Some((count, i))
}
