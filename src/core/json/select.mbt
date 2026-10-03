///|
/// Location of a selected value in the document text.
priv struct Hit {
  start : Int
  end : Int
  kind : Kind
}

///|
/// Walks `path` through `doc`, scanning only what is needed. Returns None when
/// the path does not exist; then the whole document has been validated (SQL
/// Server reports malformed text rather than a missing property).
fn select(doc : String, path : Path, doc_state : Int) -> Hit? raise JsonError {
  let s : Scanner = { text: doc, pos: 0, doc_state, }
  s.ws()
  if !(s.peek() is (0x7B | 0x5B)) {
    raise s.fail()
  }
  let mut depth = 0
  let mut found = true
  for step in path.steps {
    check_depth(depth)
    match (step, s.peek()) {
      (Key(k), 0x7B) => {
        s.pos += 1
        s.ws()
        found = false
        if s.peek() != 0x7D {
          while true {
            let key = s.string_value()
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
              0x7D => break
              _ => raise s.fail()
            }
          }
        }
      }
      (Index(i), 0x5B) => {
        s.pos += 1
        s.ws()
        found = false
        if s.peek() != 0x5D {
          let mut idx = 0
          while true {
            if idx == i {
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
              0x5D => break
              _ => raise s.fail()
            }
            idx += 1
          }
        }
      }
      _ => found = false
    }
    if !found {
      break
    }
    depth += 1
  }
  if !found {
    validate_document(doc, doc_state)
    return None
  }
  let start = s.pos
  let kind = s.skip_value(depth)
  Some({ start, end: s.pos, kind, })
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
