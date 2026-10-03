// INSERT/UPDATE/DELETE through views, CTEs and derived tables: the target is
// reduced to one base table of the query's FROM (captures: harness/corpus/
// views/*, output/updatable-cte, traps/view-updatable-rules).

///|
priv enum ViewKind {
  KView(check~ : Bool)
  KCte
  KDerived
}

///|
/// What the statement writes through the view: the (lowercased) view
/// columns assigned by UPDATE SET or listed by INSERT; DELETE writes rows.
priv enum DmlPurpose {
  PUpdate(Array[String])
  PDelete
  PInsert(Array[String])
}

///|
/// A view, CTE or derived table resolved to the base table it modifies.
/// Leaf rows are [visible view columns] ++ [underlying row]; `refresh`
/// recomputes view columns bottom-up after the base image changed:
/// (destination, source offset, expressions bound on row[source:]).
priv struct ViewTarget {
  name : String
  scope : Int
  table : @store.Table
  leaf : @bind.DmlLeaf
  /// View column → base column index (None: derived or another table).
  base_of : Array[Int?]
  /// View column depends only on the modified base table.
  modified : Array[Bool]
  refresh : Array[(Int, Int, Array[@ir.Expr])]
  /// WITH CHECK OPTION predicates: (offset, predicate on row[offset:]).
  checks : Array[(Int, @ir.Expr)]
  /// WHEREs of every level (a CHECK OPTION cascades to them).
  wheres : Array[(Int, @ir.Expr)]
  /// Metadata of the inserted/deleted images.
  result : Array[@ir.ResultColumn]
}

///|
fn ViewTarget::width(self : ViewTarget) -> Int {
  self.leaf.columns.length()
}

///|
priv enum ViewItem {
  Direct(Int) // column of the FROM row
  Derived(@ast.Expr)
}

///|
fn view_error(kind : ViewKind, number : Int, name : String) -> @types.SqlError {
  match (number, kind) {
    (4406, KDerived) =>
      @types.sql_error(
        4421,
        "Derived table '\{name}' is not updatable because a column of the derived table is derived or constant.",
      )
    (4406, _) =>
      @types.sql_error(
        4406,
        "Update or insert of view or function '\{name}' failed because it contains a derived or constant field.",
      )
    (4403, _) =>
      @types.sql_error(
        4403,
        "Cannot update the view or function '\{name}' because it contains aggregates, or a DISTINCT or GROUP BY clause, or PIVOT or UNPIVOT operator.",
      )
    _ =>
      @types.sql_error(
        4405,
        "View or function '\{name}' is not updatable because the modification affects multiple base tables.",
      )
  }
}

///|
/// FROM leaves (tables, derived tables, ...) of a FROM list, joins flattened.
fn from_leaves(from : Array[@ast.TableRef]) -> Array[@ast.TableRef] {
  let out = []
  fn walk(r : @ast.TableRef) {
    match r.kind {
      Join(_, l, rr, ..) => {
        walk(l)
        walk(rr)
      }
      _ => out.push(r)
    }
  }

  for r in from {
    walk(r)
  }
  out
}

///|
fn leaf_qualifier(r : @ast.TableRef) -> String? {
  match r.kind {
    Table(name, alias_~, ..) =>
      Some(
        match alias_ {
          Some(a) => a.name.to_lower()
          None => name.base().to_lower()
        },
      )
    TableVar(name, alias_~, ..) =>
      Some(
        match alias_ {
          Some(a) => a.name.to_lower()
          None => name.to_lower()
        },
      )
    Derived(_, alias_~, ..)
    | TableFunc(_, _, alias_~, ..)
    | Nodes(_, _, alias_~, ..) => alias_.map(a => a.name.to_lower())
    Values(_, alias_~, ..) => Some(alias_.name.to_lower())
    Pivot(_, _, alias_~) => Some(alias_.name.to_lower())
    Join(_, _, _, ..) => None
  }
}

///|
fn base_binding(scope : Int, t : @store.Table) -> @bind.TableBinding {
  {
    scope,
    id: t.id,
    schema: t.schema,
    name: t.name,
    columns: table_columns(t),
  }
}

///|
/// Resolves `query` (the body of a view, CTE or derived table named
/// `name`) for a modification described by `purpose`.
fn Session::view_target(
  self : Session,
  env : @bind.Env,
  query : @ast.Query,
  names : Array[@ast.Ident],
  name : String,
  kind : ViewKind,
  purpose : DmlPurpose,
) -> ViewTarget raise {
  let what = match kind {
    KView(..) => "a view"
    KCte => "a common table expression"
    KDerived => "a derived table"
  }
  guard query.body is Select(s) &&
    query.ctes.is_empty() &&
    query.order_by.is_empty() &&
    query.offset is None &&
    query.fetch is None &&
    query.for_clause is None &&
    s.top is None &&
    !s.from.is_empty() else {
    raise @types.not_supported(
      "INSERT/UPDATE/DELETE through \{what} that is not a plain SELECT ... FROM ... WHERE",
    )
  }
  // which FROM leaf each view column comes from
  let (_, cols) = @bind.bind_sources(env, s.from)
  let cenv = env.with_columns(cols)
  let items : Array[(String, ViewItem)] = []
  for item in s.items {
    match item.kind {
      Star(q) => {
        let want = if q.is_empty() {
          ""
        } else {
          q[q.length() - 1].name.to_lower()
        }
        for i, c in cols {
          if !c.qualifier.has_prefix("%") && (want == "" || c.qualifier == want) {
            items.push((c.name, Direct(i)))
          }
        }
      }
      ExprItem(e, alias_~) => {
        let item_name = match (alias_, e.kind) {
          (Some(a), _) => a.name
          (None, Column(parts)) => parts[parts.length() - 1].name
          _ => ""
        }
        // aggregates are never updatable: 4406/4403 before binding them
        if e.kind is Column(_) && !@bind.has_aggregate(e) {
          match @bind.bind_expr(cenv, e).kind {
            Col(i) => items.push((item_name, Direct(i)))
            _ => items.push((item_name, Derived(e)))
          }
        } else {
          items.push((item_name, Derived(e)))
        }
      }
      Assign(_, _, _) =>
        raise @types.not_supported("INSERT/UPDATE/DELETE through \{what}")
    }
  }
  let col_names = items.mapi((i, it) => {
    if i < names.length() {
      names[i].name
    } else {
      it.0
    }
  })
  let aggregate = s.distinct ||
    !s.group_by.is_empty() ||
    s.having is Some(_) ||
    s.items
    .iter()
    .any(it => it.kind is ExprItem(e, ..) && @bind.has_aggregate(e))
  let find = (n : String) => {
    let mut at = -1
    for i, cn in col_names {
      if cn.to_lower() == n {
        at = i
        break
      }
    }
    if at < 0 {
      raise @types.sql_error(207, "Invalid column name '\{n}'.")
    }
    at
  }
  // the modified leaf
  let leaves = from_leaves(s.from)
  let (target_q, inner_purpose) = match purpose {
    PDelete => {
      if aggregate {
        raise view_error(kind, 4403, name)
      }
      if leaves.length() != 1 {
        raise view_error(kind, 4405, name)
      }
      (leaf_qualifier(leaves[0]).unwrap_or(""), PDelete)
    }
    PUpdate(written) | PInsert(written) => {
      // INSERT without a column list writes every view column
      let written = if purpose is PInsert([]) {
        col_names.map(c => c.to_lower())
      } else {
        written
      }
      let idx = written.map(w => find(w))
      for i in idx {
        if items[i].1 is Derived(_) {
          raise view_error(kind, 4406, name)
        }
      }
      if aggregate {
        raise view_error(kind, 4403, name)
      }
      let qs : Array[String] = []
      let inner_names = []
      for i in idx {
        guard items[i].1 is Direct(c) else { continue }
        if !qs.contains(cols[c].qualifier) {
          qs.push(cols[c].qualifier)
        }
        inner_names.push(cols[c].name.to_lower())
      }
      if qs.length() > 1 {
        raise view_error(kind, 4405, name)
      }
      let q = if qs.is_empty() {
        if leaves.length() != 1 {
          raise view_error(kind, 4405, name)
        }
        leaf_qualifier(leaves[0]).unwrap_or("")
      } else {
        qs[0]
      }
      (
        q,
        if purpose is PInsert(_) {
          PInsert(inner_names)
        } else {
          PUpdate(inner_names)
        },
      )
    }
  }
  let leaf_ref = match
    leaves.search_by(r => leaf_qualifier(r) == Some(target_q)) {
    Some(i) => leaves[i]
    None => raise @types.not_supported("INSERT/UPDATE/DELETE through \{what}")
  }
  // the leaf is a base table, or (recursively) another view or CTE
  let (base, inner) : ((Int, @store.Table)?, ViewTarget?) = match
    leaf_ref.kind {
    Table(lname, ..) =>
      match env.find_cte(lname) {
        Some(cte) =>
          (
            None,
            Some(
              self.view_target(
                cte.env,
                cte.def.query,
                cte.def.columns,
                cte.def.name.name,
                KCte,
                inner_purpose,
              ),
            ),
          )
        None =>
          match self.find_view(lname) {
            Some((m, vq, vnames)) =>
              (
                None,
                Some(
                  self.view_target(
                    self.view_env(),
                    vq,
                    vnames,
                    m.name,
                    KView(check=m.check_option),
                    inner_purpose,
                  ),
                ),
              )
            None =>
              match self.find_table(lname) {
                Some((scope, t)) => (Some((scope, t)), None)
                None =>
                  raise @types.sql_error(
                    208,
                    "Invalid object name '\{lname.parts.map(p => p.name).join(".")}'.",
                  )
              }
          }
      }
    _ => raise @types.not_supported("INSERT/UPDATE/DELETE through \{what}")
  }
  let (scope, table) = match (inner, base) {
    (Some(v), _) => (v.scope, v.table)
    (None, Some(b)) => b
    (None, None) =>
      raise @types.not_supported("INSERT/UPDATE/DELETE through \{what}")
  }
  let binding = base_binding(scope, table)
  let src = @bind.bind_dml_source(
    env,
    s.from,
    binding,
    [target_q],
    view=inner.map(v => v.leaf),
  )
  let ienv = env.with_columns(src.columns)
  let exprs = items.map(it => {
    match it.1 {
      Derived(e) => @bind.bind_expr(ienv, e)
      Direct(c) => {
        // same FROM layout as phase 1 except the leaf's hidden columns
        let ref_ = cols[c]
        let mut at = -1
        for j, x in src.columns {
          if x.qualifier == ref_.qualifier && x.name == ref_.name {
            at = j
            break
          }
        }
        let x = src.columns[at]
        @ir.Expr::{ kind: Col(at), ty: x.ty, nullable: x.nullable, }
      }
    }
  })
  let where_ = s.where_.map(w => @bind.bind_expr(ienv, w))
  let k = exprs.length()
  let w = src.columns.length()
  let mut plan = src.plan
  match where_ {
    Some(p) => plan = Filter(plan, p)
    None => ()
  }
  let passthrough = Array::makei(w, i => {
    let c = src.columns[i]
    @ir.Expr::{ kind: Col(i), ty: c.ty, nullable: c.nullable, }
  })
  plan = Project(plan, exprs + passthrough)
  let visible = exprs.mapi((i, e) => @bind.ColumnRef::{
    qualifier: "",
    name: col_names[i],
    ty: e.ty,
    nullable: e.nullable,
    origin: Computed,
  })
  let hidden = src.columns.map(c => {
    ..c,
    qualifier: "%h",
    name: "%" + c.name,
  })
  let leaf : @bind.DmlLeaf = {
    plan,
    columns: visible + hidden,
    visible: k,
    base: k + src.base,
    rowid: k + src.rowid,
  }
  let lo = src.leaf_start
  let hi = src.leaf_start + src.leaf_width
  let n = binding.columns.length()
  let base_of = exprs.map(e => {
    match e.kind {
      Col(i) if i >= lo && i < hi =>
        match inner {
          Some(v) =>
            if i - lo < v.leaf.visible {
              v.base_of[i - lo]
            } else {
              None
            }
          None => if i - lo < n { Some(i - lo) } else { None }
        }
      _ => None
    }
  })
  let modified = exprs.map(e => {
    match e.kind {
      Col(i) => i >= lo && i < hi
      _ => true
    }
  })
  let shift = k + lo
  let refresh = match inner {
    Some(v) => v.refresh.map(x => (x.0 + shift, x.1 + shift, x.2))
    None => []
  }
  refresh.push((0, k, exprs))
  let wheres = match inner {
    Some(v) => v.wheres.map(x => (x.0 + shift, x.1))
    None => []
  }
  let checks = match inner {
    Some(v) => v.checks.map(x => (x.0 + shift, x.1))
    None => []
  }
  match where_ {
    Some(p) => wheres.push((k, p))
    None => ()
  }
  if kind is KView(check=true) {
    for x in wheres {
      checks.push(x)
    }
  }
  let result = exprs.mapi((i, e) => {
    let origin : @ir.Origin = match (items[i].1, kind) {
      (Direct(c), _) => cols[c].origin
      // captured: computed view columns keep 0x08 (views/dml-single-table),
      // computed CTE/derived columns report only nullability
      (Derived(_), KView(..)) => BaseColumn(identity=false)
      (Derived(_), _) => Aggregate
    }
    @ir.ResultColumn::{
      name: col_names[i],
      ty: e.ty,
      nullable: e.nullable,
      origin,
    }
  })
  {
    name,
    scope,
    table,
    leaf,
    base_of,
    modified,
    refresh,
    checks,
    wheres,
    result,
  }
}

///|
/// The environment a view body binds in: no caller variables or CTEs.
fn Session::view_env(self : Session) -> @bind.Env {
  @bind.Env::new(Map([]), catalog=self.catalog())
}

///|
/// A view in the user database with its parsed query and column list.
fn Session::find_view(
  self : Session,
  name : @ast.ObjectName,
) -> (@store.Module, @ast.Query, Array[@ast.Ident])? raise {
  if name.base().has_prefix("#") {
    return None
  }
  match self.find_module(name) {
    Some(m) if m.kind is View => {
      if self
        .db_of(0)
        .modules()
        .iter()
        .any(t => t.kind is Trigger && t.parent == Some(m.id) && !t.disabled) {
        raise @types.not_supported(
          "INSERT/UPDATE/DELETE on a view with triggers",
        )
      }
      let (q, cols) = view_query(m)
      Some((m, q, cols))
    }
    _ => None
  }
}

///|
/// Recomputes the view columns of a leaf row (`row` starts at the leaf).
fn Session::view_refresh(
  self : Session,
  v : ViewTarget,
  row : Array[@types.Value],
) -> Array[@types.Value] raise {
  let r = row.copy()
  for step in v.refresh {
    let (dest, src, exprs) = step
    let ctx = self.ctx().with_row(r[src:].to_owned())
    for j, e in exprs {
      r[dest + j] = @exec.eval(ctx, e)
    }
  }
  r
}

///|
/// The leaf row of a base-table image (INSERT: other columns NULL).
fn Session::view_row_of(
  self : Session,
  v : ViewTarget,
  old_leaf : Array[@types.Value]?,
  base_row : Array[@types.Value],
) -> Array[@types.Value] raise {
  let r = match old_leaf {
    Some(l) => l.copy()
    None => Array::make(v.width(), @types.Value::Null)
  }
  for i, x in base_row {
    r[v.leaf.base + i] = x
  }
  self.view_refresh(v, r)
}

///|
/// WITH CHECK OPTION: 550 when the new row leaves a checked view.
fn Session::view_check(
  self : Session,
  v : ViewTarget,
  leaf_row : Array[@types.Value],
) -> Unit raise {
  for c in v.checks {
    let ctx = self.ctx().with_row(leaf_row[c.0:].to_owned())
    if !@exec.is_true(@exec.eval(ctx, c.1)) {
      raise @types.sql_error(
        550, "The attempted insert or update failed because the target view either specifies WITH CHECK OPTION or spans a view that specifies WITH CHECK OPTION and one or more rows resulting from the operation did not qualify under the CHECK OPTION constraint.",
      )
    }
  }
}
