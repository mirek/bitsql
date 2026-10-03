///|
/// FROM clause of UPDATE/DELETE: like `bind_from`, but the occurrence of the
/// DML target is scanned with row ids. Returns the plan, its visible
/// columns (the target's row id appears as a hidden column named "%rowid"),
/// and the positions of the target's first column and its row id.
pub fn bind_dml_source(
  env : Env,
  from : Array[@ast.TableRef],
  target : TableBinding,
  target_names : Array[String],
) -> (@ir.Plan, Array[ColumnRef], Int, Int) raise @types.SqlError {
  let found : Ref[(Int, Int)?] = Ref(None)
  fn leaf(
    r : @ast.TableRef,
    offset : Int,
  ) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
    match r.kind {
      Table(name, alias_~, ..) => {
        let base = name.base().to_lower()
        let q = match alias_ {
          Some(a) => a.name.to_lower()
          None => base
        }
        if found.val is None &&
          (
            target_names.contains(q) ||
            (alias_ is None && target_names.contains(base))
          ) {
          let cols = target.columns.map(c => { ..c, qualifier: q, })
          found.val = Some((offset, offset + cols.length()))
          cols.push({
            qualifier: "%rowid",
            name: "%rowid",
            ty: BigInt,
            nullable: false,
            origin: Computed,
          })
          (Scan(scope=target.scope, id=target.id, rowid=true), cols)
        } else {
          bind_table_ref(env, r)
        }
      }
      Join(kind, left, right, on~, ..) => {
        let (lp, lc) = leaf(left, offset)
        let (rp, rc) = leaf(right, offset + lc.length())
        let k : @ir.JoinKind = match kind {
          Inner => Inner
          Left => Left
          Right => Right
          Full => Full
          Cross => Cross
          CrossApply | OuterApply =>
            raise @types.not_supported("APPLY in UPDATE/DELETE FROM")
        }
        let lc2 = if k is (Right | Full) {
          lc.map(c => { ..c, nullable: true, })
        } else {
          lc
        }
        let rc2 = if k is (Left | Full) {
          rc.map(c => { ..c, nullable: true, })
        } else {
          rc
        }
        let cond = match on {
          Some(e) => Some(bind_expr(env.with_columns(lc + rc), e))
          None => None
        }
        (
          Join(k, lp, rp, cond, left_width=lc.length(), right_width=rc.length()),
          lc2 + rc2,
        )
      }
      _ => bind_table_ref(env, r)
    }
  }

  let mut plan : @ir.Plan = OneRow
  let mut cols : Array[ColumnRef] = []
  for i, r in from {
    let (p, c) = leaf(r, cols.length())
    if i == 0 {
      plan = p
      cols = c
    } else {
      plan = Join(
        Cross,
        plan,
        p,
        None,
        left_width=cols.length(),
        right_width=c.length(),
      )
      cols = cols + c
    }
  }
  match found.val {
    Some((start, rowid)) => (plan, cols, start, rowid)
    None => {
      // target not named in FROM: SQL Server adds it as a cross join
      let tcols = target.columns.map(c => { ..c, qualifier: target_names[0], })
      let start = cols.length()
      tcols.push({
        qualifier: "%rowid",
        name: "%rowid",
        ty: BigInt,
        nullable: false,
        origin: Computed,
      })
      (
        Join(
          Cross,
          plan,
          Scan(scope=target.scope, id=target.id, rowid=true),
          None,
          left_width=cols.length(),
          right_width=tcols.length(),
        ),
        cols + tcols,
        start,
        start + target.columns.length(),
      )
    }
  }
}
