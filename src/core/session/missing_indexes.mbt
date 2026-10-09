///|
/// Advisory estimates for simple selective scans. Costs use candidate rows,
/// not SQL Server optimizer cost units or fabricated CPU/page measurements.
priv struct MissingIndex {
  id : Int
  database : String
  object_id : Int
  equality : Array[Int]
  included : Array[Int]
  schema_columns : Array[String]
  mut executions : Int64
  mut candidates : Double
  mut impact : Double
  mut last_time : Int64
}

///|
fn missing_index_shape(plan : @ir.Plan) -> (Int, Int, Array[Int], Array[Int])? {
  match plan {
    Sort(input, _) => missing_index_shape(input)
    Project(Sort(input, _), exprs) => missing_index_shape(Project(input, exprs))
    Project(Filter(Scan(scope~, id~, rowid=false), pred), exprs) => {
      let equality = []
      fn constant(e : @ir.Expr) -> Bool {
        match e.kind {
          Lit(_) | Var(_) => true
          Cast(x, ..) => constant(x)
          _ => false
        }
      }
      fn keys(e : @ir.Expr) -> Bool {
        match e.kind {
          And(a, b) => keys(a) && keys(b)
          Cmp(Eq, { kind: Col(c), .. }, value, _) if constant(value) => {
            if !equality.contains(c) {
              equality.push(c)
            }
            true
          }
          _ => false
        }
      }
      if !keys(pred) || equality.is_empty() {
        return None
      }
      let included = []
      for e in exprs {
        guard e.kind is Col(c) else { return None }
        if !equality.contains(c) && !included.contains(c) {
          included.push(c)
        }
      }
      Some((scope, id, equality, included))
    }
    _ => None
  }
}

///|
fn missing_index_covered(
  t : @store.Table,
  equality : Array[Int],
  included : Array[Int],
) -> Bool {
  t.indexes.any(ix => {
    !ix.disabled &&
    ix.filter is None &&
    ix.columns.length() <= equality.length() &&
    ix.columns.all(c => equality.contains(c.0)) &&
    included.all(c => {
      ix.clustered || ix.included.contains(c) || ix.columns.any(k => k.0 == c)
    })
  })
}

///|
fn Session::observe_missing_index(
  self : Session,
  plan : @ir.Plan,
  returned : Int64,
) -> Unit {
  guard missing_index_shape(plan) is Some((scope, id, equality, included)) &&
    scope != 2 &&
    scope != 1 &&
    scope != 3 else {
    return
  }
  let db = self.db_of(scope)
  guard db.table(id) is Some(t) else { return }
  if missing_index_covered(t, equality, included) {
    return
  }
  let candidates = db.rows(id).length().to_int64()
  if candidates <= 1L || returned >= candidates {
    return
  }
  let database = self.scope_key(scope)
  let key = (database, id, equality, included)
  let impact = 100.0 *
    (candidates - returned).to_double() /
    candidates.to_double()
  match self.server.missing_indexes.get(key) {
    Some(advice) => {
      advice.executions += 1L
      advice.candidates += candidates.to_double()
      advice.impact += impact
      advice.last_time = self.rt.now
    }
    None => {
      if self.server.missing_indexes.length() >= 600 {
        return
      }
      self.server.next_missing_index += 1
      self.server.missing_indexes[key] = {
        id: self.server.next_missing_index,
        database,
        object_id: id,
        equality,
        included,
        schema_columns: t.columns.map(c => c.name),
        executions: 1L,
        candidates: candidates.to_double(),
        impact,
        last_time: self.rt.now,
      }
    }
  }
}

///|
fn Server::missing_index_rows(self : Server, out : Array[VRow]) -> Unit {
  for _, advice in self.missing_indexes {
    guard self.database_id(advice.database) is Some(dbid) else { continue }
    guard self.get_db_key(advice.database).table(advice.object_id) is Some(t) else {
      continue
    }
    if t.columns.map(c => c.name) != advice.schema_columns {
      continue
    }
    if missing_index_covered(t, advice.equality, advice.included) {
      continue
    }
    let names = (cols : Array[Int]) => {
      if cols.is_empty() {
        @types.Value::Null
      } else {
        s(cols.map(c => bracket(t.columns[c].name)).join(", "))
      }
    }
    out.push(
      vrow([
        ("index_handle", i(advice.id)),
        ("index_group_handle", i(advice.id)),
        ("group_handle", i(advice.id)),
        ("database_id", SmallInt(dbid)),
        ("object_id", i(advice.object_id)),
        ("equality_columns", names(advice.equality)),
        ("included_columns", names(advice.included)),
        (
          "statement",
          s(
            bracket(self.database_name(advice.database)) +
            "." +
            bracket(t.schema) +
            "." +
            bracket(t.name),
          ),
        ),
        ("unique_compiles", BigInt(advice.executions)),
        ("user_seeks", BigInt(advice.executions)),
        ("user_scans", BigInt(0L)),
        ("system_seeks", BigInt(0L)),
        ("system_scans", BigInt(0L)),
        ("last_user_seek", dt(advice.last_time)),
        (
          "avg_total_user_cost",
          Float(advice.candidates / advice.executions.to_double()),
        ),
        (
          "avg_user_impact",
          Float(advice.impact / advice.executions.to_double()),
        ),
        ("avg_total_system_cost", Float(0.0)),
        ("avg_system_impact", Float(0.0)),
      ]),
    )
  }
}
