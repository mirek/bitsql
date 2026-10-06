///|
fn json_corruption_error(state : Int) -> SqlError {
  sql_error(
    13643,
    "Encountered corrupted JSON type. Please run DBCC CHECKTABLE with EXTENDED_LOGICAL_CHECKS to identify the rows. The remedy is to delete the rows and insert the JSON documents as character strings.",
    state~,
  )
}

///|
fn JsonStorageNode::has_corruption(self : JsonStorageNode) -> Bool {
  match self {
    NCorruptArray(_, _) => true
    NArray(children, _) => children.any(c => c.has_corruption())
    NObject(children, _) => children.any(c => c.1.has_corruption())
    _ => false
  }
}

///|
pub fn JsonData::checked_text(self : JsonData) -> String raise SqlError {
  if self.corrupted {
    raise json_corruption_error(8)
  }
  if self.raw_strings {
    self.root.validate_raw_strings()
  }
  self.text
}

///|
pub fn JsonData::is_corrupt(self : JsonData) -> Bool {
  self.corrupted || (self.raw_strings && self.root.has_invalid_raw_strings())
}

///|
/// Native navigation sees no elements in a copied narrow array header.
/// Materializing the container separately validates its source format.
pub fn JsonData::navigation_text(self : JsonData) -> String {
  if !self.corrupted {
    return self.text
  }
  let out = StringBuilder()
  self.root.write(out, navigation=true)
  out.to_string()
}

///|
fn JsonData::path_nodes(
  self : JsonData,
  path : String,
) -> Array[JsonStorageNode] raise SqlError {
  let p = @json.parse_path(path, native=true) catch {
    @json.JsonError(number, state, message) =>
      raise sql_error(number, message, state~)
  }
  let mut nodes = [self.root]
  for step in p.steps {
    let next : Array[JsonStorageNode] = []
    for node in nodes {
      match node {
        NObject(children, _) =>
          for (key, child) in children {
            if child is NDeleted {
              continue
            }
            match step {
              Key(k) if k == key => {
                next.push(child)
                break
              }
              AnyKey => next.push(child)
              _ => ()
            }
          }
        NArray(children, _) => {
          let last = children.length().to_int64() - 1L
          for i, child in children {
            let n = i.to_int64()
            let take = match step {
              Index(idx) => i == idx
              AnyIndex => true
              Range(lo, hi) => n >= lo && n <= hi
              Elements(ranges) =>
                ranges.any(r => {
                  let lo = if r.0 < 0L { last } else { r.0 }
                  let hi = if r.1 < 0L { last } else { r.1 }
                  n >= lo && n <= hi
                })
              _ => false
            }
            if take {
              next.push(child)
            }
          }
        }
        _ => ()
      }
    }
    nodes = next
  }
  nodes
}

///|
pub fn JsonData::validate_path(
  self : JsonData,
  path : String,
  state? : Int = 8,
) -> Unit raise SqlError {
  if self.corrupted && self.path_nodes(path).any(n => n.has_corruption()) {
    raise json_corruption_error(state)
  }
}

///|
fn JsonStorageNode::validate_openjson_item(
  self : JsonStorageNode,
) -> Unit raise SqlError {
  match self {
    NCorruptArray(_, _) => raise json_corruption_error(48)
    NArray(children, _) => {
      if children.length() > 65535 {
        raise sql_error(
          13647, "Number of items in one object/array exceeds limit 65535 in JSON type.",
        )
      }
      for child in children {
        child.validate_openjson_item()
      }
    }
    NObject(children, _) => {
      if children.filter(c => !(c.1 is NDeleted)).length() > 65535 {
        raise sql_error(
          13647, "Number of items in one object/array exceeds limit 65535 in JSON type.",
        )
      }
      for (_, child) in children {
        child.validate_openjson_item()
      }
    }
    _ => ()
  }
}

///|
pub fn JsonData::validate_openjson(
  self : JsonData,
  path : String,
) -> Unit raise SqlError {
  if !self.wide && !self.corrupted {
    return
  }
  match self.path_nodes(path) {
    [NCorruptArray(_, _)] => raise json_corruption_error(48)
    [NArray(children, _)] =>
      for child in children {
        child.validate_openjson_item()
      }
    [NObject(children, _)] =>
      for (_, child) in children {
        child.validate_openjson_item()
      }
    _ => ()
  }
}
