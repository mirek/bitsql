///|
/// A sequence generator (CREATE SEQUENCE). Values are not transactional: a
/// rolled-back NEXT VALUE FOR stays consumed (captured:
/// sequence/not-rolled-back).
priv struct SeqState {
  ty : @types.SqlType
  mut start : Int64
  mut increment : Int64
  mut min : Int64
  mut max : Int64
  mut cycle : Bool
  /// Cache size (None: NO CACHE); 50 when CACHE has no size.
  mut cache : Int?
  /// CACHE was given with an explicit size (sys.sequences.cache_size is
  /// NULL otherwise; captured: properties/sequences-catalog.sql).
  mut cache_sized : Bool
  /// Last value handed out; None before the first (or after RESTART).
  mut current : Int64?
}

///|
fn seq_key(database : String, id : Int) -> String {
  database.to_lower() + ":" + id.to_string()
}

///|
/// Value range of a sequence type, or None when the type is not allowed.
fn seq_bounds(ty : @types.SqlType) -> (Int64, Int64)? raise @types.SqlError {
  match ty {
    TinyInt => Some((0L, 255L))
    SmallInt => Some((-32768L, 32767L))
    Int => Some((-2147483648L, 2147483647L))
    BigInt => Some((-9223372036854775808L, 9223372036854775807L))
    Decimal(p, 0) | Numeric(p, 0) => {
      if p > 18 {
        raise @types.not_supported("sequences of decimal precision above 18")
      }
      let mut m = 1L
      for _ in 0..<p {
        m = m * 10L
      }
      Some((-(m - 1L), m - 1L))
    }
    _ => None
  }
}

///|
fn seq_number(text : String) -> Int64 raise @types.SqlError {
  @string.parse_int64(text.trim(chars=" ")) catch {
    _ => raise @types.not_supported("sequence option value " + text)
  }
}

///|
/// Applies CREATE/ALTER SEQUENCE options. Returns the RESTART value request:
/// None (no RESTART), Some(None) (RESTART), Some(Some(n)) (RESTART WITH n).
fn SeqState::apply(
  self : SeqState,
  options : Array[String],
  bounds : (Int64, Int64),
) -> Int64?? raise @types.SqlError {
  let mut restart : Int64?? = None
  for o in options {
    if o.has_prefix("START WITH ") {
      self.start = seq_number(o.unsafe_substring(start=11, end=o.length()))
    } else if o.has_prefix("RESTART WITH ") {
      restart = Some(
        Some(seq_number(o.unsafe_substring(start=13, end=o.length()))),
      )
    } else if o == "RESTART" {
      restart = Some(None)
    } else if o.has_prefix("INCREMENT BY ") {
      self.increment = seq_number(o.unsafe_substring(start=13, end=o.length()))
    } else if o.has_prefix("MINVALUE ") {
      self.min = seq_number(o.unsafe_substring(start=9, end=o.length()))
    } else if o.has_prefix("MAXVALUE ") {
      self.max = seq_number(o.unsafe_substring(start=9, end=o.length()))
    } else if o == "NO MINVALUE" {
      self.min = bounds.0
    } else if o == "NO MAXVALUE" {
      self.max = bounds.1
    } else if o == "CYCLE" {
      self.cycle = true
    } else if o == "NO CYCLE" {
      self.cycle = false
    } else if o == "NO CACHE" {
      self.cache = None
      self.cache_sized = false
    } else if o == "CACHE" {
      self.cache = Some(50)
      self.cache_sized = false
    } else if o.has_prefix("CACHE ") {
      self.cache = Some(
        seq_number(o.unsafe_substring(start=6, end=o.length())).to_int(),
      )
      self.cache_sized = true
    }
  }
  restart
}

///|
/// The next value the sequence would hand out (ignoring exhaustion).
fn SeqState::base(self : SeqState) -> Int64 {
  match self.current {
    None => self.start
    Some(c) => c + self.increment
  }
}

///|
/// 11729 (informational): the cache is larger than the values left.
fn Session::seq_cache_warning(
  self : Session,
  s : SeqState,
  name : String,
  line : Int,
) -> Unit {
  guard s.cache is Some(cache) else { return }
  let b = s.base()
  // the distance can exceed Int64 (bigint range): negative means huge
  let left = if s.increment > 0L {
    if b > s.max {
      0L
    } else if s.max - b < 0L {
      9223372036854775807L
    } else {
      (s.max - b) / s.increment + 1L
    }
  } else if b < s.min {
    0L
  } else if b - s.min < 0L {
    9223372036854775807L
  } else {
    (b - s.min) / -s.increment + 1L
  }
  if left < cache.to_int64() {
    self.info(
      11729,
      1,
      "The sequence object '\{name}' cache size is greater than the number of available values.",
      line,
    )
  }
}

///|
fn Session::exec_create_sequence(
  self : Session,
  name : @ast.ObjectName,
  type_ : @ast.TypeName?,
  options : Array[String],
  start : Int,
  line : Int,
) -> Unit raise {
  let written = object_text(name)
  let ty = match type_ {
    Some(t) =>
      @bind.resolve_type(
        t,
        Declaration,
        @types.default_collation,
        preview=self.preview_enabled(),
      )
    None => BigInt
  }
  guard seq_bounds(ty) is Some(bounds) else {
    raise @types.sql_error(
      11702,
      "The sequence object '\{written}' must be of data type int, bigint, smallint, tinyint, or decimal or numeric with a scale of 0, or any user-defined data type that is based on one of the above integer data types.",
      state=2,
    )
  }
  let (schema, base) = split_name(name)
  let db = self.db_of(0)
  if self.object_name_taken(db, schema, base) {
    raise @types.sql_error(
      2714,
      "There is already an object named '\{written}' in the database.",
      state=8,
    )
  }
  let s : SeqState = {
    ty,
    start: bounds.0,
    increment: 1L,
    min: bounds.0,
    max: bounds.1,
    cycle: false,
    cache: Some(50),
    cache_sized: false,
    current: None,
  }
  let explicit_start = options.iter().any(o => o.has_prefix("START WITH "))
  ignore(s.apply(options, bounds))
  if s.increment == 0L {
    raise @types.not_supported("INCREMENT BY 0")
  }
  if !explicit_start {
    s.start = if s.increment > 0L { s.min } else { s.max }
  }
  if s.min < bounds.0 || s.max > bounds.1 || s.min >= s.max {
    raise @types.not_supported(
      "sequence MINVALUE/MAXVALUE outside the type range",
    )
  }
  if s.start < s.min || s.start > s.max {
    raise @types.sql_error(
      11703,
      "The start value for sequence object '\{written}' must be between the minimum and maximum value of the sequence object.",
    )
  }
  let m = self.define_module(Create, name, Sequence, 0, start, done=false)
  self.server.seqs[seq_key(self.rt.database, m.id)] = s
  self.seq_cache_warning(s, base, line)
  self.schema_ddl = true // no DONE of its own (captured: sequence/ddl-tokens)
}

///|
fn Session::find_sequence(
  self : Session,
  name : @ast.ObjectName,
) -> (@store.Module, SeqState)? {
  match self.find_module(name) {
    Some(m) if m.kind is Sequence =>
      match self.server.seqs.get(seq_key(self.rt.database, m.id)) {
        Some(s) => Some((m, s))
        None => None
      }
    _ => None
  }
}

///|
fn Session::exec_alter_sequence(
  self : Session,
  name : @ast.ObjectName,
  options : Array[String],
  line : Int,
) -> Unit raise {
  guard self.find_sequence(name) is Some((m, s)) else {
    raise @types.sql_error(
      15151,
      "Cannot alter the sequence '\{name.base()}', because it does not exist or you do not have permission.",
    )
  }
  let bounds = seq_bounds(s.ty).unwrap_or((s.min, s.max))
  let saved = { ..s, }
  let restart = s.apply(options, bounds)
  let start = match restart {
    Some(Some(n)) => n
    _ => s.start
  }
  if start < s.min || start > s.max || s.increment == 0L {
    s.start = saved.start
    s.increment = saved.increment
    s.min = saved.min
    s.max = saved.max
    s.cycle = saved.cycle
    s.cache = saved.cache
    raise @types.sql_error(
      11703,
      "The start value for sequence object '\{object_text(name)}' must be between the minimum and maximum value of the sequence object.",
    )
  }
  // the cache warning looks at the values left before the restart
  // (captured: RESTART of an exhausted sequence warns 11729,
  // properties/sequences-catalog.sql)
  self.seq_cache_warning(s, m.name, line)
  if restart is Some(_) {
    // RESTART WITH n also becomes the start value (captured: RESTART after
    // RESTART WITH 50 restarts at 50)
    s.start = start
    s.current = None
  }
  self.schema_ddl = true
}

///|
/// NEXT VALUE FOR (key from the binder: "database:id").
fn Session::sequence_next(
  self : Session,
  key : String,
) -> @types.Value raise @types.SqlError {
  guard self.server.seqs.get(key) is Some(s) else {
    raise @types.not_supported("NEXT VALUE FOR a dropped sequence")
  }
  // one value per row for repeated references (captured: sequence/basics)
  match self.seq_row.get(key) {
    Some((row, v)) if row == self.rt.row_seq => return v
    _ => ()
  }
  let b = s.base()
  let overflow = match s.current {
    None => false
    Some(c) =>
      if s.increment > 0L {
        c > s.max - s.increment
      } else {
        c < s.min - s.increment
      }
  }
  let v = if !overflow && b >= s.min && b <= s.max {
    b
  } else if s.cycle {
    if s.increment > 0L {
      s.min
    } else {
      s.max
    }
  } else {
    let name = match key.split(":").collect() {
      [db, id] =>
        match
          self.server
          .get_db(db.to_owned())
          .get_module(@string.parse_int(id) catch { _ => -1 }) {
          Some(m) => m.name
          None => ""
        }
      _ => ""
    }
    raise @types.sql_error(
      11728,
      "The sequence object '\{name}' has reached its minimum or maximum value. Restart the sequence object to allow new values to be generated.",
    )
  }
  s.current = Some(v)
  let out = @types.cast(BigInt(v), BigInt, s.ty)
  self.seq_row[key] = (self.rt.row_seq, out)
  out
}

///|
/// Binder hook: a sequence's key and type.
fn Session::sequence_binding(
  self : Session,
  name : @ast.ObjectName,
) -> (String, @types.SqlType)? {
  match self.find_sequence(name) {
    Some((m, s)) => Some((seq_key(self.rt.database, m.id), s.ty))
    None => None
  }
}
