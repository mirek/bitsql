///|
/// A bound OUTPUT clause. Rows are evaluated over
/// [deleted image] ++ [inserted image] ++ [extra source columns].
priv struct OutputSpec {
  exprs : Array[@ir.Expr]
  columns : Array[@ir.ResultColumn]
  into : (Target, Array[Int])?
}

///|
fn ast_has_subquery(e : @ast.Expr) -> Bool {
  let mut found = false
  walk_expr(e, x => {
    if x.kind
      is (Subquery(_) | Exists(_) | InQuery(_, _, ..) | Quantified(_, _, _, _)) {
      found = true
    }
  })
  found
}

///|
/// `inserted.x` / `deleted.x` naming a view column of a base table the
/// statement does not modify (404, captured: views/dml-join-and-rules).
fn check_unmodified_refs(
  e : @ast.Expr,
  forbidden : Array[String],
) -> Unit raise {
  if forbidden.is_empty() {
    return
  }
  let mut bad : String? = None
  walk_expr(e, x => {
    match x.kind {
      Column(parts) if parts.length() >= 2 && bad is None => {
        let q = parts[parts.length() - 2].name.to_lower()
        let n = parts[parts.length() - 1].name.to_lower()
        if (q == "inserted" || q == "deleted") && forbidden.contains(n) {
          bad = Some(parts.map(p => p.name).join("."))
        }
      }
      _ => ()
    }
  })
  match bad {
    Some(text) => raise unmodified_ref(text)
    None => ()
  }
}

///|
fn unmodified_ref(text : String) -> @types.SqlError {
  @types.sql_error(
    404,
    "The column reference \"\{text}\" is not allowed because it refers to a base table that is not being modified in this statement.",
  )
}

///|
/// Binds OUTPUT clauses for a DML statement on `target` (or through
/// `view`). `extra` are the other FROM sources' columns, which OUTPUT sees
/// only qualified (captured: output/scoping); MERGE passes its source
/// columns and `$action`.
fn Session::bind_output(
  self : Session,
  clauses : Array[@ast.OutputClause],
  target : Target,
  view : ViewTarget?,
  deleted : Bool,
  inserted : Bool,
  extra : Array[@bind.ColumnRef],
  null_deleted? : Bool = false,
  null_inserted? : Bool = false,
  trigger_check? : Bool = true,
) -> Array[OutputSpec] raise {
  if clauses.is_empty() {
    return []
  }
  let (base, forbidden) : (Array[@bind.ColumnRef], Array[String]) = match view {
    Some(v) => {
      let cols = v.result.map(c => @bind.ColumnRef::{
        untyped_null: false,
        qualifier: "",
        name: c.name,
        ty: c.ty,
        nullable: c.nullable,
        origin: c.origin,
      })
      let bad = []
      for i, c in v.result {
        if !v.modified[i] {
          bad.push(c.name.to_lower())
        }
      }
      (cols, bad)
    }
    None => {
      let insertable = self.identity_insert == Some(target.table.id)
      (
        table_columns(target.table).map(c => {
          if insertable && c.origin is BaseColumn(identity=true) {
            { ..c, origin: InsertableIdentity, }
          } else {
            c
          }
        }),
        [],
      )
    }
  }
  let cols : Array[@bind.ColumnRef] = []
  // In MERGE the deleted image is absent for INSERT actions and the
  // inserted one for DELETE actions: those images are nullable (captured:
  // dml/merge-upsert, output/dml-error-completion).
  let merge = extra.iter().any(c => c.name == "$action")
  if deleted {
    cols.append(
      base.map(c => {
        ..c,
        qualifier: "deleted",
        nullable: c.nullable || null_deleted,
      }),
    )
  }
  if inserted {
    cols.append(
      base.map(c => {
        ..c,
        qualifier: "inserted",
        nullable: c.nullable || null_inserted,
      }),
    )
  }
  cols.append(extra)
  let env = self.env().with_columns(cols)
  clauses.map(clause => {
    let exprs = []
    let columns = []
    for item in clause.items {
      match item.kind {
        Star(q) => {
          let qual = q.map(i => i.name.to_lower())
          let want = if qual.is_empty() { "" } else { qual[qual.length() - 1] }
          if want == "" {
            raise @types.sql_error(
              102,
              "Incorrect syntax near '*'.",
              severity=15,
            )
          }
          if (want == "inserted" && !inserted) ||
            (want == "deleted" && !deleted) {
            raise @types.sql_error(
              4104,
              "The multi-part identifier \"\{want}.*\" could not be bound.",
            )
          }
          if !cols.iter().any(c => c.qualifier == want) {
            raise @types.sql_error(
              107,
              "The column prefix '\{q[q.length() - 1].name}' does not match with a table name or alias name used in the query.",
              severity=15,
            )
          }
          for i, c in cols {
            if c.qualifier == want {
              if (want == "inserted" || want == "deleted") &&
                forbidden.contains(c.name.to_lower()) {
                raise unmodified_ref(q[q.length() - 1].name + "." + c.name)
              }
              exprs.push(@ir.Expr::{
                kind: Col(i),
                ty: c.ty,
                nullable: c.nullable,
              })
              columns.push(@ir.ResultColumn::{
                name: c.name,
                ty: c.ty,
                nullable: c.nullable,
                origin: c.origin,
              })
            }
          }
        }
        ExprItem(e, alias_~) => {
          if @bind.has_aggregate(e) {
            raise @types.sql_error(
              158,
              "An aggregate may not appear in the OUTPUT clause.",
              severity=15,
            )
          }
          if ast_has_subquery(e) {
            raise @types.sql_error(
              10705,
              "Subqueries are not allowed in the OUTPUT clause.",
              severity=15,
            )
          }
          // unqualified names never resolve to the pseudo-tables, and
          // (outside MERGE) not to FROM sources either
          let mut unqualified : String? = None
          walk_expr(e, x => {
            match x.kind {
              Column([single]) if unqualified is None &&
                !single.name.has_prefix("$") &&
                (!merge || target.table.column_index(single.name) is Some(_)) =>
                unqualified = Some(single.name)
              _ => ()
            }
          })
          match unqualified {
            Some(n) =>
              raise @types.sql_error(207, "Invalid column name '\{n}'.")
            None => ()
          }
          check_unmodified_refs(e, forbidden)
          let b = @bind.bind_expr(env, e)
          let origin : @ir.Origin = match (e.kind, b.kind) {
            (Column(_), Col(i)) => cols[i].origin
            _ => Computed
          }
          let name = match (alias_, e.kind) {
            (Some(a), _) => a.name
            (None, Column(parts)) => parts[parts.length() - 1].name
            _ => ""
          }
          exprs.push(b)
          columns.push(@ir.ResultColumn::{
            name,
            ty: b.ty,
            nullable: b.nullable,
            origin,
          })
        }
        Assign(_, _, _) =>
          raise @types.sql_error(102, "Incorrect syntax near '='.", severity=15)
      }
    }
    let into = match clause.into {
      None => {
        if trigger_check && self.has_enabled_trigger(target) {
          raise @types.sql_error(
            334,
            "The target table '\{target.table.name}' of the DML statement cannot have any enabled triggers if the statement contains an OUTPUT clause without INTO clause.",
          )
        }
        None
      }
      Some((r, names)) => {
        let t = self.dml_target(r)
        let idx = if names.is_empty() {
          let out = []
          for i, c in t.table.columns {
            if c.identity is None && c.computed is None && c.ty != RowVersion {
              out.push(i)
            }
          }
          out
        } else {
          names.map(n => {
            match t.table.column_index(n.name) {
              Some(i) => i
              None =>
                raise @types.sql_error(207, "Invalid column name '\{n.name}'.")
            }
          })
        }
        if exprs.length() > idx.length() {
          raise @types.sql_error(
            121,
            "The select list for the INSERT statement contains more items than the insert list. The number of SELECT values must match the number of INSERT columns.",
            severity=15,
          )
        }
        if exprs.length() < idx.length() {
          raise @types.sql_error(
            120,
            "The select list for the INSERT statement contains fewer items than the insert list. The number of SELECT values must match the number of INSERT columns.",
            severity=15,
          )
        }
        for ck in t.table.checks {
          if ck.enabled {
            raise @types.sql_error(
              333,
              "The target table '\{t.table.name}' of the OUTPUT INTO clause cannot have any enabled check constraints or any enabled rules. Found check constraint or rule '\{ck.name}'.",
            )
          }
        }
        Some((t, idx))
      }
    }
    { exprs, columns, into, }
  })
}

///|
/// Sends the COLMETADATA of an OUTPUT without INTO. SQL Server does this
/// before the statement runs, so a run-time error follows an empty (or
/// partial) result set (captured: output/stream-errors). Returns true when
/// a result set was started.
fn Session::output_header(
  self : Session,
  specs : Array[OutputSpec],
) -> Bool raise Flow {
  let mut sent = false
  for spec in specs {
    if spec.into is None {
      self.out.push(ResultSet(spec.columns.map(tds_column)))
      sent = true
    }
  }
  if self.compile_only {
    raise CompiledOnly
  }
  sent
}

///|
/// Evaluates every OUTPUT clause for one combined row.
fn Session::output_eval(
  self : Session,
  specs : Array[OutputSpec],
  row : Array[@types.Value],
) -> Array[Array[@types.Value]] raise {
  if specs.is_empty() {
    return []
  }
  let ctx = self.ctx().with_row(row)
  specs.map(spec => spec.exprs.map(e => @exec.eval(ctx, e)))
}

///|
/// Streams evaluated OUTPUT rows to the client. Rows produced before a
/// failing row are sent before its error (captured: output/stream-errors).
fn Session::output_send(
  self : Session,
  specs : Array[OutputSpec],
  evaluated : ArrayView[Array[Array[@types.Value]]],
) -> Unit {
  for k, spec in specs {
    if spec.into is None {
      for v in evaluated {
        self.out.push(Row(v[k].map(wire_value)))
      }
    }
  }
}

///|
/// Inserts evaluated OUTPUT rows INTO their tables.
fn Session::output_into(
  self : Session,
  specs : Array[OutputSpec],
  evaluated : Array[Array[Array[@types.Value]]],
) -> Unit raise {
  for k, spec in specs {
    guard spec.into is Some((target, idx)) else { continue }
    let t = target.table
    let mut db = self.db_of(target.scope)
    for ev in evaluated {
      let v = ev[k]
      let row = Array::make(t.columns.length(), @types.Value::Null)
      for j, ci in idx {
        row[ci] = self.to_column(target, t.columns[ci], v[j], spec.exprs[j].ty)
      }
      for i, c in t.columns {
        if c.identity is Some(id) {
          row[i] = identity_value(c.ty, self.next_identity(t, id))
        } else if row[i] is Null && c.default_ is Some(d) && !idx.contains(i) {
          row[i] = self.eval_text(target, d, row, c.ty)
        }
      }
      self.check_row(target, db, row, "INSERT")
      db = insert_checked(target, db, self.server.rowid(), row)
    }
    self.write(target.scope, db)
  }
}

///|
/// Sends all OUTPUT rows and performs OUTPUT INTO.
fn Session::output_finish(
  self : Session,
  specs : Array[OutputSpec],
  evaluated : Array[Array[Array[@types.Value]]],
) -> Unit raise {
  self.output_send(specs, evaluated[:])
  self.output_into(specs, evaluated)
}
