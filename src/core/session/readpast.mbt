///|
/// 650: READPAST needs READ COMMITTED or REPEATABLE READ (captured:
/// tail5/b2-readpast, tail/table-hints-gaps). Class 16; it ends the batch
/// and rolls back an open transaction (ENVCHANGE after the ERROR).
fn readpast_error() -> @types.SqlError {
  @types.sql_error(
    650, "You can only specify the READPAST lock in the READ COMMITTED or REPEATABLE READ isolation levels.",
  )
}

///|
/// The isolation a READPAST read runs under: the table's hint class, else
/// the session level ("RU", "RC", "RR", "SR", "SN").
fn Session::readpast_class(self : Session, hint : String) -> String {
  if hint != "" {
    return hint
  }
  match self.isolation {
    "READ UNCOMMITTED" => "RU"
    "REPEATABLE READ" => "RR"
    "SERIALIZABLE" => "SR"
    "SNAPSHOT" => "SN"
    _ => "RC"
  }
}

///|
/// `%READPAST(hint class, view)`: evaluated when a FROM table read with
/// READPAST opens. Reads under READ UNCOMMITTED, SERIALIZABLE or SNAPSHOT
/// (hint or session level; RCSI is fine) fail with 650, also for point
/// lookups on the primary key (captured). Through a view the rule is not
/// captured: 50100.
fn Session::readpast_check(
  self : Session,
  args : Array[@types.Value],
) -> @types.Value raise @types.SqlError {
  let hint = match args.get(0) {
    Some(String(s)) => s
    _ => ""
  }
  let view = args.get(1) is Some(Bit(true))
  match self.readpast_class(hint) {
    "RU" | "SR" | "SN" =>
      if view {
        raise @types.not_supported(
          "READPAST on a view outside READ COMMITTED or REPEATABLE READ",
        )
      } else {
        raise readpast_error()
      }
    _ => Bit(true)
  }
}

///|
/// READPAST on an UPDATE/DELETE/MERGE target (its own hints or those of its
/// FROM occurrence). Write targets ignore a READ UNCOMMITTED session; under
/// SERIALIZABLE (hint or session) or SNAPSHOT they fail with 650 when the
/// statement starts, except an UPDATE/DELETE whose WHERE is exactly an
/// equality of every clustered primary key column with a constant or
/// variable (captured: `WHERE id = 1`, `id = @i`, `h.id = 1` pass;
/// `id IN (7, 8)`, `id = 1 AND v = 3`, a UNIQUE constraint column fail).
fn Session::readpast_target(
  self : Session,
  target : @ast.TableRef,
  from : Array[@ast.TableRef],
  where_ : @ast.Expr?,
  table : @store.Table?,
  merge~ : Bool,
) -> Unit raise @types.SqlError {
  guard target.kind is Table(name, alias_~, hints~) else { return }
  let all_hints = hints.copy()
  let q = match alias_ {
    Some(a) => a.name.to_lower()
    None => name.base().to_lower()
  }
  for leaf in from_leaves(from) {
    if leaf.kind is Table(n, alias_=a, hints=h) {
      let hit = match a {
        Some(a) => a.name.to_lower() == q
        None => n.base().to_lower() == q
      }
      if hit {
        all_hints.append(h)
      }
    }
  }
  if !all_hints.iter().any(h => h.name == "READPAST") {
    return
  }
  let cls = self.readpast_class(@bind.readpast_hint_class(all_hints))
  guard cls is ("SR" | "SN") else { return }
  if !merge && point_lookup(where_, table) {
    if cls == "SN" {
      raise @types.not_supported(
        "READPAST on a primary key lookup under SNAPSHOT isolation",
      )
    }
    return
  }
  raise readpast_error()
}

///|
/// WHERE is exactly `pk = constant-or-variable` for every column of the
/// clustered primary key (and nothing else).
fn point_lookup(where_ : @ast.Expr?, table : @store.Table?) -> Bool {
  guard where_ is Some(w) && table is Some(t) else { return false }
  guard t.indexes.iter().find_first(i => i.clustered && i.primary) is Some(pk) else {
    return false
  }
  let keys = pk.columns.map(c => t.columns[c.0].name.to_lower())
  let conj : Array[@ast.Expr] = []
  fn split(e : @ast.Expr) {
    match e.kind {
      And(a, b) => {
        split(a)
        split(b)
      }
      Paren(a) => split(a)
      _ => conj.push(e)
    }
  }
  split(w)
  let seen : Array[String] = []
  for c in conj {
    let col = match c.kind {
      Compare(Eq, a, b) =>
        match (a.kind, b.kind) {
          (Column(parts), IntLit(_) | DecimalLit(_) | StrLit(_, ..) | Var(_))
          | (IntLit(_) | DecimalLit(_) | StrLit(_, ..) | Var(_), Column(parts)) =>
            parts[parts.length() - 1].name.to_lower()
          _ => return false
        }
      _ => return false
    }
    if !keys.contains(col) || seen.contains(col) {
      return false
    }
    seen.push(col)
  }
  seen.length() == keys.length()
}
