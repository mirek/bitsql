///|
/// The DML target as a FROM item when it is a view, CTE or derived table:
/// rows are the target's visible columns followed by hidden columns (the
/// underlying row, whose base-table image starts at `base` and whose row id
/// is at `rowid`, both relative to the leaf).
pub(all) struct DmlLeaf {
  plan : @ir.Plan
  columns : Array[ColumnRef]
  visible : Int
  base : Int
  rowid : Int
}

///|
/// A bound UPDATE/DELETE source: the target occurrence spans
/// `leaf_start .. leaf_start + leaf_width`; `base` and `rowid` are absolute.
pub(all) struct DmlSource {
  plan : @ir.Plan
  columns : Array[ColumnRef]
  leaf_start : Int
  leaf_width : Int
  base : Int
  rowid : Int
}

///|
pub fn Env::with_ctes(self : Env, ctes : Array[@ast.Cte]) -> Env {
  with_ctes(self, ctes)
}

///|
/// The innermost CTE visible under `name` (one-part names only).
pub fn Env::find_cte(self : Env, name : @ast.ObjectName) -> CteDef? {
  find_cte(self, name)
}

///|
fn rowid_column() -> ColumnRef {
  {
    qualifier: "%rowid",
    name: "%rowid",
    ty: BigInt,
    nullable: false,
    origin: Computed,
  }
}

///|
/// The leaf of a base-table target: its columns under `q`, then the row id.
fn base_leaf(target : TableBinding, q : String) -> DmlLeaf {
  let cols = target.columns.map(c => { ..c, qualifier: q, })
  let n = cols.length()
  cols.push(rowid_column())
  {
    plan: Scan(scope=target.scope, id=target.id, rowid=true),
    columns: cols,
    visible: n,
    base: 0,
    rowid: n,
  }
}

///|
/// A view leaf under qualifier `q`: visible columns take the qualifier.
fn requalify_leaf(leaf : DmlLeaf, q : String) -> DmlLeaf {
  {
    ..leaf,
    columns: leaf.columns.mapi((i, c) => {
      if i < leaf.visible {
        { ..c, qualifier: q, }
      } else {
        c
      }
    }),
  }
}

///|
/// FROM clause of UPDATE/DELETE: like `bind_from`, but the occurrence of the
/// DML target is scanned with row ids (or is the given `view` leaf). A
/// target not named in FROM is cross joined, as SQL Server does.
pub fn bind_dml_source(
  env : Env,
  from : Array[@ast.TableRef],
  target : TableBinding,
  target_names : Array[String],
  view? : DmlLeaf? = None,
) -> DmlSource raise @types.SqlError {
  let found : Ref[(Int, DmlLeaf)?] = Ref(None)
  fn leaf(
    r : @ast.TableRef,
    offset : Int,
  ) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
    let take = (q : String) => {
      let l = match view {
        Some(v) => requalify_leaf(v, q)
        None => base_leaf(target, q)
      }
      found.val = Some((offset, l))
      (l.plan, l.columns)
    }
    match r.kind {
      Table(name, alias_~, ..) if found.val is None => {
        let base = name.base().to_lower()
        let q = match alias_ {
          Some(a) => a.name.to_lower()
          None => base
        }
        let hit = match view {
          Some(_) => target_names.contains(q)
          None =>
            target_names.contains(q) ||
            (alias_ is None && target_names.contains(base))
        }
        if hit {
          take(q)
        } else {
          bind_table_ref(env, r)
        }
      }
      // a table variable target named by its alias or name in FROM
      // (captured: msduck gaps-temp_tables #035)
      TableVar(name, alias_~, ..) if found.val is None && view is None => {
        let q = match alias_ {
          Some(a) => a.name.to_lower()
          None => name.to_lower()
        }
        if target_names.contains(q) {
          take(q)
        } else {
          bind_table_ref(env, r)
        }
      }
      Derived(_, alias_=Some(a), ..) if found.val is None &&
        view is Some(_) &&
        target_names.contains(a.name.to_lower()) => take(a.name.to_lower())
      // the applied side sees the left row (the target included) as its
      // outer row (captured: msduck gaps-outer_dml #017-#019)
      Join(CrossApply | OuterApply as kind, left, right, ..) => {
        let (lp, lc) = leaf(left, offset)
        let (rp, rc) = bind_table_ref(env.with_source(lc, lp), right)
        let outer = kind is OuterApply
        let rc2 = if outer { rc.map(c => { ..c, nullable: true, }) } else { rc }
        (Apply(lp, rp, outer~, right_width=rc.length()), lc + rc2)
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
  check_exposed_names(from)
  match found.val {
    Some((start, l)) =>
      {
        plan,
        columns: cols,
        leaf_start: start,
        leaf_width: l.columns.length(),
        base: start + l.base,
        rowid: start + l.rowid,
      }
    None => {
      // target not named in FROM: SQL Server adds it as a cross join
      let l = match view {
        Some(v) => requalify_leaf(v, target_names[0])
        None => base_leaf(target, target_names[0])
      }
      let start = cols.length()
      let joined : @ir.Plan = if from.is_empty() {
        l.plan
      } else {
        Join(
          Cross,
          plan,
          l.plan,
          None,
          left_width=start,
          right_width=l.columns.length(),
        )
      }
      {
        plan: joined,
        columns: cols + l.columns,
        leaf_start: start,
        leaf_width: l.columns.length(),
        base: start + l.base,
        rowid: start + l.rowid,
      }
    }
  }
}

///|
/// Binds arbitrary FROM items (MERGE USING source).
pub fn bind_sources(
  env : Env,
  from : Array[@ast.TableRef],
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  bind_from(env, from)
}
