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
/// Binds OUTPUT clauses for a DML statement on `target`.
fn Session::bind_output(
  self : Session,
  clauses : Array[@ast.OutputClause],
  target : Target,
  deleted : Bool,
  inserted : Bool,
  extra : Array[@bind.ColumnRef],
) -> Array[OutputSpec] raise {
  if clauses.is_empty() {
    return []
  }
  let base = table_columns(target.table)
  let cols : Array[@bind.ColumnRef] = []
  // In MERGE either image may be absent, so both are nullable (captured:
  // dml/merge-upsert).
  let both = deleted && inserted && extra.iter().any(c => c.name == "$action")
  if deleted {
    cols.append(
      base.map(c => { ..c, qualifier: "deleted", nullable: c.nullable || both, }),
    )
  }
  if inserted {
    cols.append(
      base.map(c => {
        ..c,
        qualifier: "inserted",
        nullable: c.nullable || both,
      }),
    )
  }
  cols.append(extra.filter(c => c.qualifier != "%rowid"))
  let env = self.env().with_columns(cols)
  clauses.map(clause => {
    let exprs = []
    let columns = []
    for item in clause.items {
      match item.kind {
        Star(q) => {
          let qual = q.map(i => i.name.to_lower())
          let want = if qual.is_empty() { "" } else { qual[qual.length() - 1] }
          if want != "inserted" && want != "deleted" {
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
          for i, c in cols {
            if c.qualifier == want {
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
          // unqualified names never resolve to the target's pseudo-tables
          match e.kind {
            Column([single]) =>
              if target.table.column_index(single.name) is Some(_) {
                raise @types.sql_error(
                  207,
                  "Invalid column name '\{single.name}'.",
                )
              }
            _ => ()
          }
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
        if self.has_enabled_trigger(target) {
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
/// Emits OUTPUT results (or inserts them INTO a table). `rows` are the
/// combined images. Returns true when a result set was sent.
fn Session::emit_output(
  self : Session,
  specs : Array[OutputSpec],
  rows : Array[Array[@types.Value]],
) -> Bool raise {
  let mut sent = false
  for spec in specs {
    let values = rows.map(r => {
      let ctx = self.ctx().with_row(r)
      spec.exprs.map(e => @exec.eval(ctx, e))
    })
    match spec.into {
      None => {
        self.out.push(ResultSet(spec.columns.map(tds_column)))
        for v in values {
          self.out.push(Row(v.map(wire_value)))
        }
        sent = true
      }
      Some((target, idx)) => {
        let t = target.table
        let mut db = self.db_of(target.scope)
        for v in values {
          let row = Array::make(t.columns.length(), @types.Value::Null)
          for j, ci in idx {
            row[ci] = self.to_column(
              target,
              t.columns[ci],
              v[j],
              spec.exprs[j].ty,
            )
          }
          for i, c in t.columns {
            if c.identity is Some(id) {
              row[i] = identity_value(c.ty, self.next_identity(t, id))
            } else if row[i] is Null &&
              c.default_ is Some(d) &&
              !idx.contains(i) {
              row[i] = self.eval_text(target, d, row, c.ty)
            }
          }
          self.check_row(target, db, row, "INSERT")
          db = insert_checked(target, db, self.server.rowid(), row)
        }
        self.write(target.scope, db)
      }
    }
  }
  sent
}
