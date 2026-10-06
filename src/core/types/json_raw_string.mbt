///|
/// Native scalar decoding truncates an incomplete final scalar. An invalid
/// byte run fails unless a subsequent complete scalar restores conversion.
/// The returned offset excludes an incomplete tail; None is error 9833.
fn json_raw_prefix(bytes : Bytes) -> Int? {
  let mut at = 0
  let mut invalid = false
  while at < bytes.length() {
    let c = bytes[at].to_int()
    let width = if c < 128 {
      1
    } else if c >= 194 && c <= 223 {
      2
    } else if c >= 224 && c <= 239 {
      3
    } else if c >= 240 && c <= 244 {
      4
    } else {
      invalid = true
      at += 1
      continue
    }
    let end = (at + width).min(bytes.length())
    for i in (at + 1)..<end {
      let b = bytes[i].to_int()
      if b < 128 || b > 191 {
        return None
      }
    }
    if at + width > bytes.length() {
      return if invalid { None } else { Some(at) }
    }
    ignore(@utf8.decode(bytes[at:end])) catch {
      _ => return None
    }
    invalid = false
    at = end
  }
  if invalid {
    None
  } else {
    Some(at)
  }
}

///|
fn json_raw_error() -> SqlError {
  sql_error(9833, "Invalid data for UTF8-encoded characters", state=2)
}

///|
fn JsonStorageNode::has_raw_strings(self : JsonStorageNode) -> Bool {
  match self {
    NRawString(_) => true
    NArray(children, _) | NCorruptArray(children, _) =>
      children.any(c => c.has_raw_strings())
    NObject(children, _) => children.any(c => c.1.has_raw_strings())
    _ => false
  }
}

///|
fn JsonStorageNode::has_invalid_raw_strings(self : JsonStorageNode) -> Bool {
  match self {
    NRawString(bytes) => json_raw_prefix(bytes) is None
    NArray(children, _) | NCorruptArray(children, _) =>
      children.any(c => c.has_invalid_raw_strings())
    NObject(children, _) => children.any(c => c.1.has_invalid_raw_strings())
    _ => false
  }
}

///|
fn JsonStorageNode::validate_raw_strings(
  self : JsonStorageNode,
) -> Unit raise SqlError {
  if self.has_invalid_raw_strings() {
    raise json_raw_error()
  }
}

///|
fn JsonStorageNode::with_raw_string(
  self : JsonStorageNode,
  steps : ArrayView[@json.Step],
  bytes : Bytes,
) -> JsonStorageNode {
  if steps.is_empty() {
    return NRawString(bytes)
  }
  match (self, steps[0]) {
    (NArray(children, capacity), Index(i)) =>
      NArray(
        children.mapi((j, child) => {
          if i == j {
            child.with_raw_string(steps[1:], bytes)
          } else {
            child
          }
        }),
        capacity,
      )
    (NObject(children, capacity), Key(key)) =>
      NObject(
        children.map(pair => {
          (
            pair.0,
            if pair.0 == key {
              pair.1.with_raw_string(steps[1:], bytes)
            } else {
              pair.1
            },
          )
        }),
        capacity,
      )
    _ => self
  }
}

///|
/// Preserve producer-supplied UTF-8 bytes before native JSON allocation.
pub fn JsonData::parse_raw_strings(
  text : String,
  strings : Array[(String, Bytes)],
) -> JsonData raise SqlError {
  let mut tree = json_storage_tree(json_type_normalize(text))
  for (path, bytes) in strings {
    let valid = try @utf8.decode(bytes[:]) catch {
      _ => false
    } noraise {
      _ => true
    }
    if valid {
      continue
    }
    let p = @json.parse_path(path) catch {
      @json.JsonError(number, state, message) =>
        raise sql_error(number, message, state~)
    }
    tree = tree.with_raw_string(p.steps[:], bytes)
  }
  JsonData::from_tree(tree)
}

///|
pub fn JsonData::scalar_text(
  self : JsonData,
  path : String,
) -> String raise SqlError {
  if !self.raw_strings {
    return self.navigation_text()
  }
  for node in self.path_nodes(path) {
    if node is NRawString(_) {
      node.validate_raw_strings()
    }
  }
  let out = StringBuilder()
  self.root.write(out, navigation=true, scalar=true)
  out.to_string()
}

///|
pub fn JsonData::query_result(
  self : JsonData,
  path : String,
  text : String,
  wrapper : Bool,
) -> JsonData raise SqlError {
  if !self.raw_strings {
    return JsonData::parse(text)
  }
  let nodes = self.path_nodes(path)
  if wrapper {
    return JsonData::from_tree(NArray(nodes, nodes.length()))
  }
  match nodes {
    [node] => JsonData::from_tree(node)
    _ => JsonData::parse(text)
  }
}

///|
pub fn JsonData::validate_raw_path(
  self : JsonData,
  path : String,
) -> Unit raise SqlError {
  if self.raw_strings {
    for node in self.path_nodes(path) {
      node.validate_raw_strings()
    }
  }
}

///|
pub fn JsonData::mutation_text(self : JsonData) -> String raise SqlError {
  if self.corrupted {
    raise json_corruption_error(8)
  }
  self.text
}
