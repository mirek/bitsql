///|
/// Location of a selected value in the document text.
priv struct Hit {
  start : Int
  end : Int
  kind : Kind
}

///|
/// What a path selected: nothing, values (in document order), or a JSON
/// null reached by a multi-value path, which ends the search at once
/// (captured: `[1,null,x]` with `$[*]` is NULL, not 13609).
priv enum Selection {
  Hits(Array[Hit])
  NullHit
}

///|
/// Starts a scan at the root, which must be an object or an array. Under
/// `lob` (an nvarchar(max)/varchar(max) argument) SQL Server reads a root
/// scalar entirely before failing (captured: @j nvarchar(max) = '1' fails
/// at position 1, a literal '1' at position 0).
fn root_scanner(
  doc : String,
  doc_state : Int,
  lob : Bool,
) -> Scanner raise JsonError {
  let s : Scanner = { text: doc, pos: 0, doc_state, }
  s.ws()
  if !(s.peek() is (0x7B | 0x5B)) {
    if lob {
      ignore(s.skip_value(0))
    }
    raise s.fail()
  }
  s
}

///|
/// Walks a single-value path, scanning only what is needed. Returns None
/// when the path does not exist. A step of the wrong kind stops without
/// reading further; a member or index missing from a container leaves that
/// container scanned, and for the root container also the text after it
/// (captured: `{"a":1} x` with `$.missing` is 13609, `{"a":{},"b":x}` with
/// `$.a.missing` and `[1,2` with `$.x` are NULL).
fn select(
  doc : String,
  path : Path,
  doc_state : Int,
  lob? : Bool = false,
) -> Hit? raise JsonError {
  let s = root_scanner(doc, doc_state, lob)
  match walk(s, path.steps, path.steps.length()) {
    Some(depth) => {
      let start = s.pos
      let kind = s.skip_value(depth)
      Some({ start, end: s.pos, kind, })
    }
    None => None
  }
}

///|
/// Follows `steps[0:count]` (single-value steps) from the root; returns the
/// depth of the reached value (the scanner sits on it) or None after the
/// miss rules of `select`.
fn walk(s : Scanner, steps : Array[Step], count : Int) -> Int? raise JsonError {
  let doc = s.text
  let mut depth = 0
  for i in 0..<count {
    let step = steps[i]
    let found = match (step, s.peek()) {
      (Key(k), 0x7B) => {
        check_depth(depth)
        s.pos += 1
        s.ws()
        let mut found = false
        if s.peek() == 0x7D {
          s.pos += 1
        } else {
          while true {
            let key = s.string_value()
            check_depth(depth + 1)
            s.ws()
            s.expect(0x3A)
            s.ws()
            if key == k {
              found = true
              break
            }
            ignore(s.skip_value(depth + 1))
            s.ws()
            match s.peek() {
              0x2C => {
                s.pos += 1
                s.ws()
              }
              0x7D => {
                s.pos += 1
                break
              }
              _ => raise s.fail()
            }
          }
        }
        if !found && depth == 0 {
          trailing(s)
        }
        found
      }
      (Index(n), 0x5B) => {
        check_depth(depth)
        s.pos += 1
        s.ws()
        let mut found = false
        if s.peek() == 0x5D {
          s.pos += 1
        } else {
          let mut idx = 0
          while true {
            if idx == n {
              found = true
              break
            }
            ignore(s.skip_value(depth + 1))
            s.ws()
            match s.peek() {
              0x2C => {
                s.pos += 1
                s.ws()
              }
              0x5D => {
                s.pos += 1
                break
              }
              _ => raise s.fail()
            }
            idx += 1
          }
        }
        if !found && depth == 0 {
          trailing(s)
        }
        found
      }
      _ => false
    }
    if !found {
      ignore(doc)
      return None
    }
    depth += 1
  }
  Some(depth)
}

///|
/// After the root container: only whitespace may follow.
fn trailing(s : Scanner) -> Unit raise JsonError {
  s.ws()
  if s.pos < s.text.length() {
    raise s.fail()
  }
}

///|
/// Evaluates a path with advanced accessors. The single-value prefix is
/// walked like `select`; from the first multi-value accessor on, every
/// candidate container is scanned (and validated) entirely, collecting the
/// values the rest of the path reaches. Inside a multi-value accessor,
/// missing members and wrong kinds are skipped even under strict (captured:
/// `strict $[*].a` over `[{"b":0},{"a":2}]` is 2). A strict range that runs
/// past the end of a non-empty array is 13659.
fn select_all(
  doc : String,
  path : Path,
  doc_state : Int,
  lob? : Bool = false,
) -> Selection raise JsonError {
  let s = root_scanner(doc, doc_state, lob)
  let mut first = 0
  while first < path.steps.length() && !path.steps[first].is_multi() {
    first += 1
  }
  let depth = match walk(s, path.steps, first) {
    Some(d) => d
    None => return Hits([])
  }
  let acc = []
  if collect(s, path, first, depth, acc) {
    NullHit
  } else {
    Hits(acc)
  }
}

///|
/// Scans the value at `s.pos` entirely, evaluating `steps[i:]` on it and
/// appending reached values to `acc`. Returns true when a JSON null was
/// reached (the caller stops at once).
fn collect(
  s : Scanner,
  path : Path,
  i : Int,
  depth : Int,
  acc : Array[Hit],
) -> Bool raise JsonError {
  let steps = path.steps
  if i == steps.length() {
    let start = s.pos
    let kind = s.skip_value(depth)
    if kind is Null {
      return true
    }
    acc.push({ start, end: s.pos, kind, })
    return false
  }
  let step = steps[i]
  match (step, s.peek()) {
    (Key(_) | AnyKey, 0x7B) => {
      check_depth(depth)
      s.pos += 1
      s.ws()
      if s.peek() == 0x7D {
        s.pos += 1
        return false
      }
      let mut matched = false
      while true {
        let key = s.string_value()
        check_depth(depth + 1)
        s.ws()
        s.expect(0x3A)
        s.ws()
        let take = match step {
          Key(k) => !matched && key == k
          _ => true
        }
        if take {
          matched = true
          if collect(s, path, i + 1, depth + 1, acc) {
            return true
          }
        } else {
          ignore(s.skip_value(depth + 1))
        }
        s.ws()
        match s.peek() {
          0x2C => {
            s.pos += 1
            s.ws()
          }
          0x7D => {
            s.pos += 1
            break
          }
          _ => raise s.fail()
        }
      }
    }
    (Index(_) | AnyIndex | Range(_, _), 0x5B) => {
      check_depth(depth)
      s.pos += 1
      s.ws()
      let mut count = 0L
      if s.peek() == 0x5D {
        s.pos += 1
      } else {
        while true {
          let take = match step {
            Index(n) => count == n.to_int64()
            Range(lo, hi) => count >= lo && count <= hi
            _ => true
          }
          if take {
            if collect(s, path, i + 1, depth + 1, acc) {
              return true
            }
          } else {
            ignore(s.skip_value(depth + 1))
          }
          count += 1
          s.ws()
          match s.peek() {
            0x2C => {
              s.pos += 1
              s.ws()
            }
            0x5D => {
              s.pos += 1
              break
            }
            _ => raise s.fail()
          }
        }
      }
      // captured: "Index 2 provided at position 7 is not within the array
      // of size 5." for `[1,2,3]` and `strict $[1 to 5]`: the last index,
      // the position after `]`, and the range end
      if step is Range(_, hi) && path.strict && count > 0L && count <= hi {
        raise JsonError(
          13659,
          1,
          "Index \{count - 1L} provided at position \{s.pos} is not within the array of size \{hi}.",
        )
      }
    }
    _ => ignore(s.skip_value(depth))
  }
  false
}

///|
fn validate_document(doc : String, doc_state : Int) -> Unit raise JsonError {
  let s : Scanner = { text: doc, pos: 0, doc_state, }
  s.ws()
  ignore(s.skip_value(0))
  s.ws()
  if s.pos < doc.length() {
    raise s.fail()
  }
}

///|
/// Scalar text of a hit: decoded string, number/boolean lexeme, None for null.
fn scalar_text(doc : String, hit : Hit) -> String? raise JsonError {
  match hit.kind {
    Null => None
    String => {
      let s : Scanner = { text: doc, pos: hit.start, doc_state: 1, }
      Some(s.string_value())
    }
    _ => Some(doc.unsafe_substring(start=hit.start, end=hit.end))
  }
}
