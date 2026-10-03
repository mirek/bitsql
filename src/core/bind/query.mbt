///|
/// A bound query: its plan and the result-set description.
pub(all) struct BoundQuery {
  plan : @ir.Plan
  columns : Array[@ir.ResultColumn]
  /// ORDER token ordinals (1-based projected positions, 0 = hidden key);
  /// empty when no ORDER BY.
  order : Array[Int]
} derive(Debug)

///|
/// Column name of the FOR JSON / FOR XML result.
pub let for_json_column : String = "JSON_F52E2B61-18A1-11d1-B105-00805F49916B"

///|
fn item_name(item : @ast.SelectItem) -> String {
  match item.kind {
    ExprItem(_, alias_=Some(a)) => a.name
    ExprItem({ kind: Column(parts), .. }, alias_=None) =>
      parts[parts.length() - 1].name
    _ => ""
  }
}

///|
/// Environment for expressions evaluated at plan level (VALUES rows, TOP
/// counts, table-function arguments): the executor runs them with an empty
/// current row, so this level has no columns and `env`'s columns are one
/// level out.
fn plan_env(env : Env) -> Env {
  env.with_columns([])
}

// ---------------------------------------------------------------- FROM

///|
/// Binds FROM into a plan and the columns it exposes.
fn bind_from(
  env : Env,
  from : Array[@ast.TableRef],
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  if from.is_empty() {
    return (OneRow, [])
  }
  let (p0, c0) = bind_table_ref(env, from[0])
  let mut plan : @ir.Plan = p0
  let mut cols = c0
  // Comma-separated FROM items are cross joins.
  for i in 1..<from.length() {
    let (p2, c2) = bind_table_ref(env, from[i])
    plan = @ir.Plan::Join(
      Cross,
      plan,
      p2,
      None,
      left_width=cols.length(),
      right_width=c2.length(),
    )
    cols = cols + c2
  }
  (plan, cols)
}

///|
fn object_text(name : @ast.ObjectName) -> String {
  name.parts.map(p => p.name).join(".")
}

///|
fn requalify(cols : Array[ColumnRef], q : String) -> Array[ColumnRef] {
  cols.map(c => { ..c, qualifier: q, })
}

///|
/// Origin of a column read back through a derived table, CTE or APPLY:
/// base columns keep theirs; computed ones lose the computed flag
/// (captured: query/derived-cte-apply, `id + 1` in a derived table is
/// flags 1, a literal 0).
fn derived_origin(o : @ir.Origin) -> @ir.Origin {
  match o {
    Computed | TableComputed => SetOperation
    other => other
  }
}

///|
/// Columns of a derived table / CTE: names from the column list or the
/// query, with SQL Server's checks (8155, 8156, 8158, 8159).
fn derived_columns(
  bq : BoundQuery,
  alias_ : String,
  qualifier : String,
  names : Array[@ast.Ident],
  deferred? : Array[@types.SqlError]? = None,
) -> Array[ColumnRef] raise @types.SqlError {
  let n = bq.columns.length()
  if !names.is_empty() && names.length() < n {
    raise err(
      8158,
      "'\{alias_}' has more columns than were specified in the column list.",
    )
  }
  if !names.is_empty() && names.length() > n {
    raise err(
      8159,
      "'\{alias_}' has fewer columns than were specified in the column list.",
    )
  }
  let out : Array[ColumnRef] = []
  for i, c in bq.columns {
    let name = if names.is_empty() { c.name } else { names[i].name }
    if name == "" {
      let e = err(
        8155,
        "No column name was specified for column \{i + 1} of '\{alias_}'.",
        state=2,
      )
      // a derived table goes on binding; a later error is reported after
      // this one (captured: query/derived-unnamed-column)
      match deferred {
        Some(list) => list.push(e)
        None => raise e
      }
    }
    for o in out {
      if o.name.to_lower() == name.to_lower() {
        raise err(
          8156,
          "The column '\{name}' was specified multiple times for '\{alias_}'.",
        )
      }
    }
    out.push({
      qualifier,
      name,
      ty: c.ty,
      nullable: c.nullable,
      origin: derived_origin(c.origin),
    })
  }
  out
}

///|
fn find_cte(env : Env, name : @ast.ObjectName) -> CteDef? {
  if name.parts.length() != 1 {
    return None
  }
  let n = name.base().to_lower()
  let mut i = env.ctes.length() - 1
  while i >= 0 {
    if env.ctes[i].name == n {
      return Some(env.ctes[i])
    }
    i -= 1
  }
  None
}

///|
fn bind_table_ref(
  env : Env,
  r : @ast.TableRef,
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  match r.kind {
    Table(name, alias_~, hints~) => {
      ignore(hints)
      match find_cte(env, name) {
        Some(cte) => {
          let q = match alias_ {
            Some(a) => a.name.to_lower()
            None => cte.name
          }
          return bind_cte_ref(env, cte, q)
        }
        None => ()
      }
      // views: bound like a derived table, without the caller's scope
      match (env.catalog.view)(name) {
        Some((vq, names)) => {
          if env.nest >= max_module_nesting {
            raise @types.not_supported(
              "views or inline functions nested more than 32 levels",
            )
          }
          let venv = {
            ..Env::new(Map([]), collation=env.collation, catalog=env.catalog),
            ids: env.ids,
            nest: env.nest + 1,
          }
          let bq = bind_query_inner(venv, vq)
          let a = match alias_ {
            Some(a) => a.name
            None => name.base()
          }
          // unlike derived tables, computed view columns keep fComputed
          // (captured: catalog/view-select)
          let cols = derived_columns(bq, a, a.to_lower(), names).mapi((i, c) => {
            if bq.columns[i].origin is (Computed | TableComputed) {
              { ..c, origin: Computed, }
            } else {
              c
            }
          })
          return (bq.plan, cols)
        }
        None => ()
      }
      match (env.catalog.table)(name) {
        Some(t) => {
          let q = match alias_ {
            Some(a) => a.name.to_lower()
            None => t.name.to_lower()
          }
          (Scan(scope=t.scope, id=t.id, rowid=false), requalify(t.columns, q))
        }
        None => raise err(208, "Invalid object name '\{object_text(name)}'.")
      }
    }
    TableVar(name, alias_~, ..) =>
      match env.table_var(name) {
        Some(t) => {
          let q = match alias_ {
            Some(a) => a.name.to_lower()
            None => name.to_lower()
          }
          (Scan(scope=t.scope, id=t.id, rowid=false), requalify(t.columns, q))
        }
        None =>
          raise err(
            1087,
            "Must declare the table variable \"\{name}\".",
            state=1,
            severity=15,
          )
      }
    Join(kind, left, right, on~, ..) => {
      let (lp, lc) = bind_table_ref(env, left)
      if kind is (CrossApply | OuterApply) {
        // the right side sees the left row as its innermost outer row
        let (rp, rc) = bind_table_ref(env.with_source(lc, lp), right)
        let outer = kind is OuterApply
        let rc2 = if outer { rc.map(c => { ..c, nullable: true, }) } else { rc }
        return (Apply(lp, rp, outer~, right_width=rc.length()), lc + rc2)
      }
      let (rp, rc) = bind_table_ref(env, right)
      let k : @ir.JoinKind = match kind {
        Inner => Inner
        Left => Left
        Right => Right
        Full => Full
        _ => Cross
      }
      // outer joins make the other side's columns nullable
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
      let cols = lc2 + rc2
      let cond = match on {
        Some(e) => {
          if has_aggregate(e) {
            raise aggregate_in_where()
          }
          Some(
            bind_expr(
              env.with_source(
                lc + rc,
                Join(
                  Cross,
                  lp,
                  rp,
                  None,
                  left_width=lc.length(),
                  right_width=rc.length(),
                ),
              ),
              e,
            ),
          )
        }
        None => None
      }
      (
        Join(k, lp, rp, cond, left_width=lc.length(), right_width=rc.length()),
        cols,
      )
    }
    Values(rows, alias_~, columns~) => {
      let penv = plan_env(env)
      let bound = rows.map(r => r.map(e => bind_expr(penv, e)))
      let width = bound[0].length()
      for r in bound {
        if r.length() != width {
          raise err(
            10709, "The number of columns for each row in a table value constructor must be the same.",
          )
        }
      }
      if columns.length() != width {
        raise err(
          8158,
          "'\{alias_.name}' has more columns than were specified in the column list.",
        )
      }
      let cols = []
      for j in 0..<width {
        let t = unify_non_null(
          bound.map(r => (r[j].ty, r[j].kind is Lit(Null))),
        )
        let nullable = bound.iter().any(r => r[j].nullable)
        cols.push(ColumnRef::{
          qualifier: alias_.name.to_lower(),
          name: columns[j].name,
          ty: t,
          nullable,
          // captured: VALUES columns report flags 0 (msduck output-dml)
          origin: SetOperation,
        })
      }
      let rows2 = []
      for r in bound {
        let out = []
        for j, e in r {
          out.push(coerce(e, cols[j].ty))
        }
        rows2.push(out)
      }
      (Values(rows2), cols)
    }
    Derived(q, alias_~, columns~) => {
      let bq = bind_query_inner(env, q)
      let a = match alias_ {
        Some(a) => a.name
        None => ""
      }
      (
        bq.plan,
        derived_columns(
          bq,
          a,
          a.to_lower(),
          columns,
          deferred=Some(env.deferred),
        ),
      )
    }
    TableFunc(name, args, openjson_with~, alias_~, columns~) =>
      bind_table_function(env, name, args, openjson_with, alias_, columns)
    Nodes(target, args, alias_~, columns~) =>
      bind_nodes_ref(env, target, args, alias_, columns)
  }
}

///|
fn query_mentions(q : @ast.Query, name : String) -> Bool {
  body_mentions(q.body, name)
}

///|
fn body_mentions(b : @ast.QueryBody, name : String) -> Bool {
  match b {
    Select(s) => s.from.iter().any(r => ref_mentions(r, name))
    SetOperation(_, l, r) => body_mentions(l, name) || body_mentions(r, name)
    Nested(q) => query_mentions(q, name)
  }
}

///|
fn ref_mentions(r : @ast.TableRef, name : String) -> Bool {
  match r.kind {
    Table(n, ..) => n.parts.length() == 1 && n.base().to_lower() == name
    Join(_, a, b, ..) => ref_mentions(a, name) || ref_mentions(b, name)
    Derived(q, ..) => query_mentions(q, name)
    _ => false
  }
}

///|
/// Flattens a recursive CTE body into its UNION ALL members.
fn union_all_members(b : @ast.QueryBody, out : Array[@ast.QueryBody]) -> Unit {
  match b {
    SetOperation(UnionAll, l, r) => {
      union_all_members(l, out)
      union_all_members(r, out)
    }
    other => out.push(other)
  }
}

///|
/// A reference to a CTE: non-recursive CTEs are re-bound at each use;
/// recursive ones become a `Recursive` plan over a work table.
fn bind_cte_ref(
  env : Env,
  cte : CteDef,
  qualifier : String,
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  match cte.work {
    Some((id, cols)) => return (WorkTable(id), requalify(cols, qualifier))
    None => ()
  }
  let def = cte.def
  let denv = { ..cte.env, maxrecursion: env.maxrecursion, }
  if !query_mentions(def.query, cte.name) {
    let bq = bind_query_inner(denv, def.query)
    return (bq.plan, derived_columns(bq, def.name.name, qualifier, def.columns))
  }
  let members = []
  union_all_members(def.query.body, members)
  let anchors = members.filter(m => !body_mentions(m, cte.name))
  let recs = members.filter(m => body_mentions(m, cte.name))
  if anchors.is_empty() {
    raise err(
      246,
      "No anchor member was specified for recursive query \"\{def.name.name}\".",
    )
  }
  if !def.query.order_by.is_empty() || def.query.offset is Some(_) {
    raise @types.not_supported("ORDER BY in a recursive CTE")
  }
  let anchor = bind_union_all(denv, anchors)
  let cols0 = derived_columns(anchor, def.name.name, cte.name, def.columns)
  // recursive CTE columns are nullable (captured: IntN flags 1)
  let cols = cols0.map(c => {
    ..c,
    nullable: true,
    origin: derived_origin(c.origin),
  })
  let id = env.ids.val
  env.ids.val = id + 1
  let self_def : CteDef = { ..cte, work: Some((id, cols)), }
  let renv = { ..denv, ctes: denv.ctes + [self_def], }
  let rec_plans = []
  for m in recs {
    let bq = bind_body(renv, m)
    if bq.columns.length() != cols.length() {
      raise err(
        205, "All queries combined using a UNION, INTERSECT or EXCEPT operator must have an equal number of expressions in their target lists.",
      )
    }
    for j, c in bq.columns {
      if c.ty != cols[j].ty {
        raise err(
          240,
          "Types don't match between the anchor and the recursive part in column \"\{cols[j].name}\" of recursive query \"\{def.name.name}\".",
        )
      }
    }
    rec_plans.push(bq.plan)
  }
  let rec_plan : @ir.Plan = if rec_plans.length() == 1 {
    rec_plans[0]
  } else {
    UnionAll(rec_plans)
  }
  (
    Recursive(id~, anchor.plan, rec_plan, max=env.maxrecursion),
    requalify(cols, qualifier),
  )
}

///|
/// OPENJSON and STRING_SPLIT in FROM / APPLY.
fn bind_table_function(
  env : Env,
  name : @ast.ObjectName,
  args : Array[@ast.Expr],
  openjson_with : Array[@ast.OpenJsonColumn]?,
  alias_ : @ast.Ident?,
  columns : Array[@ast.Ident],
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  let fname = name.base().to_upper()
  let q = match alias_ {
    Some(a) => a.name.to_lower()
    None => fname.to_lower()
  }
  let penv = plan_env(env)
  let col = (n : String, ty : @types.SqlType, nullable : Bool) => ColumnRef::{
    qualifier: q,
    name: n,
    ty,
    nullable,
    origin: SetOperation,
  }
  if fname != "OPENJSON" && fname != "STRING_SPLIT" {
    match bind_user_tvf(env, name, args, alias_, columns) {
      Some(r) => return r
      None =>
        if name.parts.length() > 1 {
          raise err(208, "Invalid object name '\{object_text(name)}'.")
        }
    }
  }
  let (plan, cols) : (@ir.Plan, Array[ColumnRef]) = match fname {
    "OPENJSON" => {
      arity_range(fname, args, 1, 2)
      let bound = args.map(a => bind_expr(penv, a))
      match openjson_with {
        None =>
          (
            TableFunc(OpenJsonDefault, bound),
            [
              col("key", NVarChar(Some(4000), openjson_key_collation), false),
              col("value", NVarChar(None, env.collation), true),
              col("type", TinyInt, false),
            ],
          )
        Some(schema) => {
          let jc : Array[@ir.OpenJsonColumn] = []
          let cs : Array[ColumnRef] = []
          for c in schema {
            let ty = resolve_type(c.type_, Declaration, env.collation)
            if c.as_json && !(ty is NVarChar(None, _)) {
              raise err(
                13618, "AS JSON option can be specified only for column of nvarchar(max) type in WITH clause.",
              )
            }
            let path = match c.path {
              Some(p) => p
              None => "$." + c.name.name
            }
            jc.push({ path, as_json: c.as_json, ty, })
            cs.push(col(c.name.name, ty, true))
          }
          (TableFunc(OpenJsonWith(jc), bound), cs)
        }
      }
    }
    "STRING_SPLIT" => {
      arity_range(fname, args, 2, 3)
      let s = bind_expr(penv, args[0])
      let sep = bind_expr(penv, args[1])
      let ordinal = if args.length() == 3 {
        match args[2].kind {
          IntLit("0") => false
          IntLit("1") => true
          _ =>
            raise @types.not_supported(
              "STRING_SPLIT enable_ordinal other than a 0/1 literal",
            )
        }
      } else {
        false
      }
      let vty : @types.SqlType = match s.ty {
        Char(n, c) => VarChar(Some(n), c)
        NChar(n, c) => NVarChar(Some(n), c)
        VarChar(_, _) | NVarChar(_, _) => s.ty
        Int if s.kind is Lit(Null) => VarChar(Some(1), env.collation)
        other =>
          raise @types.not_supported("STRING_SPLIT of \{other.base_name()}")
      }
      let cs = [col("value", vty, s.nullable)]
      if ordinal {
        cs.push(col("ordinal", BigInt, false))
      }
      (TableFunc(StringSplit(ordinal~), [s, sep]), cs)
    }
    _ =>
      raise @types.not_supported("table-valued function \{object_text(name)}")
  }
  if !columns.is_empty() {
    if columns.length() != cols.length() {
      raise @types.not_supported("table function column aliases")
    }
    return (plan, cols.mapi((i, c) => { ..c, name: columns[i].name, }))
  }
  (plan, cols)
}

// ------------------------------------------------------- clause errors

///|
fn aggregate_in_where() -> @types.SqlError {
  err(
    147,
    "An aggregate may not appear in the WHERE clause unless it is in a subquery contained in a HAVING clause or a select list, and the column being aggregated is an outer reference.",
    severity=15,
  )
}

///|
fn window_misplaced() -> @types.SqlError {
  err(
    4108,
    "Windowed functions can only appear in the SELECT or ORDER BY clauses.",
    severity=15,
  )
}

///|
priv enum Clause {
  SelectList
  Having
  OrderBy
}

///|
/// Binds an expression of a grouped query; a column that exists in the
/// FROM row but is neither grouped nor aggregated is 8120/8121/8127.
fn bind_clause(
  env : Env,
  inner : Env,
  e : @ast.Expr,
  clause : Clause,
  grouped : Bool,
) -> @ir.Expr raise @types.SqlError {
  bind_expr(env, e) catch {
    @types.SqlError(number=207 | 4104, ..) as failure if grouped => {
      let bad : Ref[ColumnRef?] = Ref(None)
      ignore(
        any_expr(e, x => {
          match x.kind {
            Column(parts) if bad.val is None =>
              if resolve_column(env, parts) is None {
                match resolve_column(inner, parts) {
                  Some({ kind: Col(i), .. }) => bad.val = Some(inner.columns[i])
                  _ => ()
                }
              }
            _ => ()
          }
          false
        }),
      )
      match bad.val {
        Some(c) => {
          let name = if c.qualifier == "" {
            c.name
          } else {
            c.qualifier + "." + c.name
          }
          match clause {
            SelectList =>
              raise err(
                8120,
                "Column '\{name}' is invalid in the select list because it is not contained in either an aggregate function or the GROUP BY clause.",
              )
            Having =>
              raise err(
                8121,
                "Column '\{name}' is invalid in the HAVING clause because it is not contained in either an aggregate function or the GROUP BY clause.",
              )
            OrderBy =>
              raise err(
                8127,
                "Column \"\{name}\" is invalid in the ORDER BY clause because it is not contained in either an aggregate function or the GROUP BY clause.",
              )
          }
        }
        None => raise failure
      }
    }
    other => raise other
  }
}

///|
fn resolve_column(env : Env, parts : Array[@ast.Ident]) -> @ir.Expr? {
  Some(bind_column(env, parts)) catch {
    _ => None
  }
}

// ------------------------------------------------------------ grouping

///|
fn synthetic(name : String) -> @ast.Expr {
  let span = @ast.Span::{ start: 0, end: 0, line: 0, col: 0, }
  { kind: Column([{ name, quoted: true, span, }]), span, }
}

///|
/// GROUP BY state: keys bound against the FROM row, aggregates collected
/// while rewriting the select list / HAVING / ORDER BY.
priv struct Grouping {
  inner : Env
  keys : Array[@ir.Expr]
  key_cols : Array[ColumnRef]
  /// expr_key of each key's AST (for expression keys)
  key_text : Array[String]
  aggs : Array[@ir.AggCall]
  agg_text : Array[String]
  mut sets : Array[Array[Int]]
  /// WITHIN GROUP ordering of the first ordered aggregate (8711 check)
  mut ordering : String?
}

///|
fn Grouping::add_key(
  self : Grouping,
  e : @ast.Expr,
) -> Int raise @types.SqlError {
  if any_expr(e, is_aggregate, subqueries=true) || has_window(e) {
    raise err(
      144,
      "Cannot use an aggregate or a subquery in an expression used for the group by list of a GROUP BY clause.",
      severity=15,
    )
  }
  let b = bind_expr(self.inner, e)
  if b.ty is Xml {
    raise xml_not_comparable()
  }
  let text = expr_key(e)
  for i, k in self.keys {
    match (k.kind, b.kind) {
      (Col(x), Col(y)) if x == y => return i
      _ => if self.key_text[i] == text { return i }
    }
  }
  let i = self.keys.length()
  self.keys.push(b)
  self.key_text.push(text)
  self.key_cols.push(
    match b.kind {
      Col(c) => self.inner.columns[c]
      // captured: a grouped expression reads back without the computed flag
      _ =>
        {
          qualifier: "",
          name: "\u{1}k\{i}",
          ty: b.ty,
          nullable: b.nullable,
          origin: Aggregate,
        }
    },
  )
  i
}

///|
/// Grouping sets of one GROUP BY item; None for a plain expression.
fn Grouping::item_sets(
  self : Grouping,
  item : @ast.GroupItem,
) -> Array[Array[Int]] raise @types.SqlError {
  let tuple = (es : Array[@ast.Expr]) => {
    let out = []
    for e in es {
      out.push(self.add_key(e))
    }
    out
  }
  match item {
    GroupExpr(e) => [[self.add_key(e)]]
    GroupEmpty => [[]]
    GroupTuple(es) => [tuple(es)]
    Rollup(groups) => {
      let gs = []
      for g in groups {
        gs.push(tuple(g))
      }
      let out = []
      let mut n = gs.length()
      while n >= 0 {
        let s = []
        for i in 0..<n {
          s.append(gs[i])
        }
        out.push(s)
        n -= 1
      }
      out
    }
    Cube(groups) => {
      let gs = []
      for g in groups {
        gs.push(tuple(g))
      }
      let n = gs.length()
      let out = []
      // full set first, grand total last
      let mut mask = (1 << n) - 1
      while mask >= 0 {
        let s = []
        for i in 0..<n {
          if ((mask >> (n - 1 - i)) & 1) == 1 {
            s.append(gs[i])
          }
        }
        out.push(s)
        mask -= 1
      }
      out
    }
    GroupingSets(items) => {
      let out = []
      for it in items {
        out.append(self.item_sets(it))
      }
      out
    }
  }
}

///|
/// Replaces grouped expressions and aggregate calls with references to the
/// aggregated row.
fn Grouping::rewrite(
  self : Grouping,
  e : @ast.Expr,
) -> @ast.Expr raise @types.SqlError {
  map_expr(e, x => {
    let text = expr_key(x)
    for i, k in self.key_text {
      if k == text && !(self.keys[i].kind is Col(_)) {
        return Some(synthetic(self.key_cols[i].name))
      }
    }
    guard is_aggregate(x) && x.kind is Call(call) else { return None }
    for i, t in self.agg_text {
      if t == text {
        return Some(synthetic("\u{1}a\{i}"))
      }
    }
    let name = call.name.base().to_upper()
    let agg : @ir.AggCall = if name == "GROUPING" || name == "GROUPING_ID" {
      let ks = []
      for a in call.args {
        let b = bind_expr(self.inner, a)
        let t = expr_key(a)
        let mut found = -1
        for i, k in self.keys {
          match (k.kind, b.kind) {
            (Col(p), Col(q)) if p == q => found = i
            _ => if self.key_text[i] == t { found = i }
          }
        }
        if found < 0 {
          raise err(
            8161,
            "Argument 1 of the \{name} function does not match any of the expressions in the GROUP BY clause.",
          )
        }
        ks.push(found)
      }
      let f : @ir.AggFn = if name == "GROUPING" {
        arity(name, call.args, 1)
        Grouping(ks[0])
      } else {
        GroupingId(ks)
      }
      {
        func: f,
        arg: None,
        separator: None,
        distinct: false,
        order: [],
        ty: agg_result_type(f, None, self.inner),
      }
    } else {
      if !call.within_group.is_empty() {
        let text = call.within_group
          .map(o => expr_key(o.expr) + (if o.desc { " desc" } else { "" }))
          .join(",")
        match self.ordering {
          Some(t) if t != text =>
            raise err(
              8711, "Multiple ordered aggregate functions in the same scope have mutually incompatible orderings.",
            )
          _ => self.ordering = Some(text)
        }
      }
      bind_agg_call(self.inner, call)
    }
    let i = self.aggs.length()
    self.aggs.push(agg)
    self.agg_text.push(text)
    Some(synthetic("\u{1}a\{i}"))
  })
}

///|
/// Columns of the aggregated row: keys, aggregates, then the grouping id.
fn Grouping::columns(self : Grouping) -> Array[ColumnRef] {
  let rolled = !self.sets.is_empty()
  let out = self.key_cols.map(c => {
    if rolled {
      { ..c, nullable: true, }
    } else {
      c
    }
  })
  for i, a in self.aggs {
    out.push({
      qualifier: "",
      name: "\u{1}a\{i}",
      ty: a.ty,
      // captured: GROUPING() is a NOT NULL computed tinyint (flags 32)
      nullable: !(a.func is (Grouping(_) | GroupingId(_))),
      origin: if a.func is (Grouping(_) | GroupingId(_)) {
        Computed
      } else {
        Aggregate
      },
    })
  }
  if rolled {
    out.push({
      qualifier: "",
      name: "\u{1}gid",
      ty: BigInt,
      nullable: false,
      origin: Aggregate,
    })
  }
  out
}

///|
fn cross_sets(
  a : Array[Array[Int]],
  b : Array[Array[Int]],
) -> Array[Array[Int]] {
  let out = []
  for x in a {
    for y in b {
      let s = x.copy()
      for k in y {
        if !s.contains(k) {
          s.push(k)
        }
      }
      out.push(s)
    }
  }
  out
}

// -------------------------------------------------------------- SELECT

///|
/// Binds `SELECT ... [ORDER BY] [OFFSET/FETCH]` into a plan that ends with
/// the projection.
fn bind_select_query(
  env : Env,
  s : @ast.Select,
  order_by : Array[@ast.OrderItem],
  offset : @ast.Expr?,
  fetch : @ast.Expr?,
  assign? : Array[(Int, @types.SqlType)]? = None,
) -> BoundQuery raise @types.SqlError {
  if s.into is Some(_) {
    raise @types.not_supported("SELECT INTO here")
  }
  let (source, cols) = bind_from(env, s.from)
  let inner = env.with_source(cols, source)
  let mut plan = match s.where_ {
    Some(w) => {
      if has_aggregate(w) {
        raise aggregate_in_where()
      }
      if has_window(w) {
        raise window_misplaced()
      }
      @ir.Plan::Filter(source, bind_expr(inner, w))
    }
    None => source
  }
  let item_exprs : Array[@ast.Expr?] = s.items.map(i => {
    match i.kind {
      ExprItem(e, ..) => Some(e)
      Assign(_, _, e) => Some(e)
      Star(_) => None
    }
  })
  let grouped = !s.group_by.is_empty() ||
    s.having is Some(_) ||
    item_exprs.iter().any(e => e is Some(x) && has_aggregate(x)) ||
    order_by.iter().any(o => has_aggregate(o.expr))
  let mut items = item_exprs
  let mut having = s.having
  let mut orders = order_by.map(o => o.expr)
  let mut base = inner
  if grouped {
    let g : Grouping = {
      inner,
      keys: [],
      key_cols: [],
      key_text: [],
      aggs: [],
      agg_text: [],
      sets: [],
      ordering: None,
    }
    let mut sets : Array[Array[Int]] = [[]]
    let mut plain = true
    for item in s.group_by {
      if !(item is GroupExpr(_)) {
        plain = false
      }
      sets = cross_sets(sets, g.item_sets(item))
    }
    g.sets = if plain { [] } else { sets }
    items = items.map(e => {
      match e {
        Some(x) => Some(g.rewrite(x))
        None => None
      }
    })
    having = match having {
      Some(h) => {
        if has_window(h) {
          raise window_misplaced()
        }
        Some(g.rewrite(h))
      }
      None => None
    }
    orders = orders.map(o => g.rewrite(o))
    plan = Aggregate(plan, g.keys, g.aggs, sets=g.sets)
    base = env.with_source(g.columns(), plan)
    match having {
      Some(h) => plan = Filter(plan, bind_clause(base, inner, h, Having, true))
      None => ()
    }
  }
  // window functions: appended to the (grouped) row
  let wins : Array[@ir.WindowCall] = []
  let win_rewrite = (e : @ast.Expr) => {
    map_expr(e, x => {
      guard is_window(x) && x.kind is Call(call) else { return None }
      let w = bind_window_call(base, call)
      let i = wins.length()
      wins.push(w)
      Some(synthetic("\u{1}w\{i}"))
    })
  }
  items = items.map(e => {
    match e {
      Some(x) => Some(win_rewrite(x))
      None => None
    }
  })
  orders = orders.map(o => win_rewrite(o))
  let full = if wins.is_empty() {
    base
  } else {
    plan = Window(plan, wins)
    let wc = base.columns.copy()
    for i, w in wins {
      wc.push({
        qualifier: "",
        name: "\u{1}w\{i}",
        ty: w.ty,
        nullable: true,
        origin: Aggregate,
      })
    }
    env.with_columns(wc)
  }
  // projection
  let exprs : Array[@ir.Expr] = []
  let result : Array[@ir.ResultColumn] = []
  for idx, item in s.items {
    match item.kind {
      Star(qualifier) => {
        if cols.is_empty() {
          raise err(263, "Must specify table to select from.", severity=16)
        }
        let q = qualifier.map(i => i.name.to_lower())
        for i, c in cols {
          if q.is_empty() || q[q.length() - 1] == c.qualifier {
            let b = if grouped {
              let parts : Array[@ast.Ident] = [
                { name: c.qualifier, quoted: true, span: item.span, },
                { name: c.name, quoted: true, span: item.span, },
              ]
              let e : @ast.Expr = { kind: Column(parts), span: item.span, }
              bind_clause(full, inner, e, SelectList, true)
            } else {
              mk(Col(i), c.ty, c.nullable)
            }
            exprs.push(b)
            result.push(@ir.ResultColumn::{
              name: c.name,
              ty: c.ty,
              nullable: c.nullable,
              origin: c.origin,
            })
          }
        }
      }
      ExprItem(_, ..) => {
        let b = bind_clause(
          full,
          inner,
          items[idx].unwrap(),
          SelectList,
          grouped,
        )
        let origin : @ir.Origin = match b.kind {
          // also a column after constant folding (CASE WHEN 1=1 THEN col ...)
          Col(i) => full.columns[i].origin
          // captured: NEXT VALUE FOR has flags 0 (sequence/basics)
          Call(Named("NEXT VALUE FOR"), _) => SetOperation
          _ => Computed
        }
        exprs.push(b)
        result.push(@ir.ResultColumn::{
          name: item_name(item),
          ty: b.ty,
          nullable: b.nullable,
          origin,
        })
      }
      Assign(name, op, _) => {
        guard assign is Some(targets) else {
          raise err(
            141,
            "A SELECT statement that assigns a value to a variable must not be combined with data-retrieval operations.",
            severity=15,
          )
        }
        let info = match env.vars.get(name.to_lower()) {
          Some(v) => v
          None =>
            raise err(
              137,
              "Must declare the scalar variable \"\{name}\".",
              state=2,
              severity=15,
            )
        }
        let rhs = bind_clause(
          full,
          inner,
          items[idx].unwrap(),
          SelectList,
          grouped,
        )
        let value = compound_assign(info, op, rhs)
        targets.push((info.slot, info.ty))
        exprs.push(value)
        result.push(@ir.ResultColumn::{
          name,
          ty: value.ty,
          nullable: true,
          origin: Computed,
        })
      }
    }
  }
  // ORDER BY
  let keys : Array[@ir.SortKey] = []
  let order : Array[Int] = []
  for i, o in order_by {
    let (key, ordinal) = order_key(
      full,
      inner,
      o.expr,
      orders[i],
      s.items,
      result,
      exprs,
      grouped,
    )
    keys.push(@ir.SortKey::{
      expr: key,
      desc: o.desc,
      collation: key.ty.collation(),
    })
    order.push(ordinal)
  }
  let top = match s.top {
    Some(t) => {
      if t.with_ties && order_by.is_empty() {
        raise err(
          1062,
          "The TOP N WITH TIES clause is not allowed without a corresponding ORDER BY clause.",
          severity=15,
        )
      }
      let penv = plan_env(env)
      let c = bind_expr(penv, t.count)
      Some((coerce(c, if t.percent { Float } else { BigInt }), t))
    }
    None => None
  }
  xml_sort_check(keys)
  if s.distinct {
    xml_distinct_check(result)
    plan = Project(plan, exprs)
    plan = Distinct(plan, result.map(c => c.ty.collation()))
    if !keys.is_empty() {
      let pkeys = []
      for i, k in keys {
        if order[i] == 0 {
          raise err(
            145,
            "ORDER BY items must appear in the select list if SELECT DISTINCT is specified.",
            severity=15,
          )
        }
        let j = order[i] - 1
        pkeys.push(@ir.SortKey::{
          ..k,
          expr: mk(Col(j), result[j].ty, result[j].nullable),
        })
      }
      plan = Sort(plan, pkeys)
      plan = limit(env, plan, top, pkeys, offset, fetch)
    } else {
      plan = limit(env, plan, top, [], offset, fetch)
    }
  } else {
    if !keys.is_empty() {
      plan = Sort(plan, keys)
    }
    plan = limit(env, plan, top, keys, offset, fetch)
    plan = Project(plan, exprs)
  }
  // a hidden sort key (ORDER ordinal 0) clears fComputed on every computed
  // column: literal 32 -> 0, nullable expression 33 -> 1 (captured:
  // query/order-hidden-key, docs/reference/result-metadata.md)
  // ...except a reference to a table's computed column, which keeps 33
  // (captured: traps/order-by-hidden-key-flags)
  let result = if order.contains(0) {
    result.mapi((i, c) => {
      match (i < exprs.length() && exprs[i].kind is Col(_), c.origin) {
        (true, TableComputed) => c
        // a view's computed column reads as a base column (33 -> 9)
        (true, Computed) => { ..c, origin: BaseColumn(identity=false), }
        _ => { ..c, origin: derived_origin(c.origin), }
      }
    })
  } else {
    result
  }
  { plan, columns: result, order, }
}

///|
/// `@v = e` / `@v += e` as the value to store.
fn compound_assign(
  info : VarInfo,
  op : @ast.AssignOp,
  rhs : @ir.Expr,
) -> @ir.Expr raise @types.SqlError {
  let aop : @types.ArithOp = match op {
    Assign => return rhs
    AddAssign => Add
    SubAssign => Sub
    MulAssign => Mul
    DivAssign => Div
    ModAssign => Mod
    _ => raise @types.not_supported("bitwise compound assignment in SELECT")
  }
  let current = mk(Var(info.slot), info.ty, true)
  let ty = @types.arith_result_type(aop, info.ty, rhs.ty)
  mk(Arith(aop, current, rhs), ty, true)
}

///|
fn limit(
  env : Env,
  plan : @ir.Plan,
  top : (@ir.Expr, @ast.Top)?,
  keys : Array[@ir.SortKey],
  offset : @ast.Expr?,
  fetch : @ast.Expr?,
) -> @ir.Plan raise @types.SqlError {
  match top {
    Some((c, t)) =>
      Top(plan, c, percent=t.percent, ties=if t.with_ties { keys } else { [] })
    None =>
      if offset is None && fetch is None {
        plan
      } else {
        let penv = plan_env(env)
        let off = match offset {
          Some(o) => Some(coerce(bind_expr(penv, o), BigInt))
          None => None
        }
        let cnt = match fetch {
          Some(f) => Some(coerce(bind_expr(penv, f), BigInt))
          None => None
        }
        Limit(plan, off, cnt)
      }
  }
}

///|
/// An ORDER BY key and its ORDER token ordinal (msduck docs/order-token.md:
/// output alias, position or a projected expression → its ordinal; other
/// keys → 0).
fn order_key(
  full : Env,
  inner : Env,
  original : @ast.Expr,
  rewritten : @ast.Expr,
  items : Array[@ast.SelectItem],
  result : Array[@ir.ResultColumn],
  exprs : Array[@ir.Expr],
  grouped : Bool,
) -> (@ir.Expr, Int) raise @types.SqlError {
  match original.kind {
    IntLit(n) => {
      let i = parse_style(n)
      if i < 1 || i > exprs.length() {
        raise err(
          108,
          "The ORDER BY position number \{n} is out of range of the number of items in the select list.",
          severity=15,
        )
      }
      return (exprs[i - 1], i)
    }
    Column([name]) =>
      for i, c in result {
        if c.name != "" && c.name.to_lower() == name.name.to_lower() {
          return (exprs[i], i + 1)
        }
      }
    _ => ()
  }
  let key = bind_clause(full, inner, rewritten, OrderBy, grouped)
  let text = expr_key(original)
  // a key calling a user function is never matched to a select item
  // (captured: udf/scalar-basics, ORDER 0)
  // (likewise an xml method call: captured xml/methods#053)
  let user_call = any_expr(original, x => {
    (x.kind is Call({ name, .. }) && name.parts.length() > 1) ||
    x.kind is MethodCall(_, _, _)
  })
  for i, item in items {
    match item.kind {
      ExprItem(e, ..) if !user_call && expr_key(e) == text =>
        return (exprs[i], i + 1)
      _ => ()
    }
  }
  match key.kind {
    Col(k) =>
      for i, x in exprs {
        if x.kind is Col(j) && j == k {
          return (key, i + 1)
        }
      }
    _ => ()
  }
  (key, 0)
}

// ------------------------------------------------------ query / set ops

///|
/// Binds a query below the statement level (derived tables, subqueries,
/// CTE bodies, set-operation operands).
fn bind_query_inner(
  env : Env,
  q : @ast.Query,
  top_level? : Bool = false,
) -> BoundQuery raise @types.SqlError {
  if q.for_clause is Some(_) {
    return bind_for_subquery(env, q)
  }
  let has_top = match q.body {
    Select({ top: Some(_), .. }) => true
    _ => false
  }
  if !top_level && !q.order_by.is_empty() && !has_top && q.offset is None {
    raise err(
      1033,
      "The ORDER BY clause is invalid in views, inline functions, derived tables, subqueries, and common table expressions, unless TOP, OFFSET or FOR XML is also specified.",
      severity=15,
    )
  }
  if has_top && (q.offset is Some(_) || q.fetch is Some(_)) {
    raise err(
      10741,
      "A TOP can not be used in the same query or sub-query as a OFFSET.",
      state=2,
      severity=15,
    )
  }
  let env = with_ctes(env, q.ctes)
  match q.body {
    Select(s) => bind_select_query(env, s, q.order_by, q.offset, q.fetch)
    _ => {
      let bq = bind_body(env, q.body)
      order_set_result(env, bq, q)
    }
  }
}

///|
fn with_ctes(env : Env, ctes : Array[@ast.Cte]) -> Env {
  let mut e = env
  for c in ctes {
    let def : CteDef = {
      name: c.name.name.to_lower(),
      def: c,
      env: e,
      work: None,
    }
    e = { ..e, ctes: e.ctes + [def], }
  }
  e
}

///|
/// ORDER BY / OFFSET over a set operation: keys must name result columns
/// (104 otherwise).
fn order_set_result(
  env : Env,
  bq : BoundQuery,
  q : @ast.Query,
) -> BoundQuery raise @types.SqlError {
  if q.order_by.is_empty() && q.offset is None && q.fetch is None {
    return bq
  }
  let keys = []
  let order = []
  for o in q.order_by {
    let j = match o.expr.kind {
      IntLit(n) => {
        let i = parse_style(n)
        if i < 1 || i > bq.columns.length() {
          raise err(
            108,
            "The ORDER BY position number \{n} is out of range of the number of items in the select list.",
            severity=15,
          )
        }
        i - 1
      }
      Column(parts) => {
        let name = parts[parts.length() - 1].name.to_lower()
        let mut found = -1
        for i, c in bq.columns {
          if c.name.to_lower() == name {
            found = i
            break
          }
        }
        found
      }
      _ => -1
    }
    if j < 0 {
      raise err(
        104, "ORDER BY items must appear in the select list if the statement contains a UNION, INTERSECT or EXCEPT operator.",
      )
    }
    let c = bq.columns[j]
    keys.push(@ir.SortKey::{
      expr: mk(Col(j), c.ty, c.nullable),
      desc: o.desc,
      collation: c.ty.collation(),
    })
    order.push(j + 1)
  }
  let mut plan = bq.plan
  xml_sort_check(keys)
  if !keys.is_empty() {
    plan = Sort(plan, keys)
  }
  plan = limit(env, plan, None, keys, q.offset, q.fetch)
  { ..bq, plan, order, }
}

///|
/// Binds a set-operation operand or tree. Results are projected to the
/// unified column types.
fn bind_body(env : Env, b : @ast.QueryBody) -> BoundQuery raise @types.SqlError {
  match b {
    Select(s) => bind_select_query(env, s, [], None, None)
    Nested(q) => bind_query_inner(env, q)
    SetOperation(UnionAll, _, _) => {
      let parts = []
      flatten_union_all(b, parts)
      bind_union_all(env, parts)
    }
    SetOperation(op, l, r) => {
      let bl = bind_body(env, l)
      let br = bind_body(env, r)
      check_width(bl, br)
      let columns = []
      let op_name = match op {
        Union => "UNION"
        Except => "EXCEPT"
        _ => "INTERSECT"
      }
      for j, c in bl.columns {
        let t = unify_non_null([
          (c.ty, null_literal_column(bl.plan, j)),
          (br.columns[j].ty, null_literal_column(br.plan, j)),
        ])
        let t = match set_op_collation(env, op_name, bl, br, j) {
          Some(coll) => with_collation(t, coll)
          None => t
        }
        columns.push(
          match op {
            // captured: EXCEPT / INTERSECT keep the left operand's metadata
            Except | Intersect => { ..c, ty: t, }
            _ =>
              @ir.ResultColumn::{
                name: c.name,
                ty: t,
                nullable: c.nullable || br.columns[j].nullable,
                origin: SetOperation,
              }
          },
        )
      }
      xml_set_op_check(columns)
      let kind : @ir.SetOpKind = match op {
        Union => Union
        Except => Except
        _ => Intersect
      }
      {
        plan: SetOp(
          kind,
          convert_to(bl, columns),
          convert_to(br, columns),
          columns.map(c => c.ty.collation()),
        ),
        columns,
        order: [],
      }
    }
  }
}

///|
fn check_width(a : BoundQuery, b : BoundQuery) -> Unit raise @types.SqlError {
  if a.columns.length() != b.columns.length() {
    raise err(
      205, "All queries combined using a UNION, INTERSECT or EXCEPT operator must have an equal number of expressions in their target lists.",
    )
  }
}

///|
/// Projects a bound query's rows to the given column types.
fn convert_to(
  bq : BoundQuery,
  columns : Array[@ir.ResultColumn],
) -> @ir.Plan raise @types.SqlError {
  let same = bq.columns.iter().zip(columns.iter()).all(p => p.0.ty == p.1.ty)
  if same {
    return bq.plan
  }
  let exprs = []
  for j, c in bq.columns {
    exprs.push(coerce(mk(Col(j), c.ty, c.nullable), columns[j].ty))
  }
  Project(bq.plan, exprs)
}

///|
fn bind_union_all(
  env : Env,
  parts : Array[@ast.QueryBody],
) -> BoundQuery raise @types.SqlError {
  let bound = parts.map(p => bind_body(env, p))
  if bound.length() == 1 {
    return bound[0]
  }
  for b in bound {
    check_width(bound[0], b)
  }
  let columns = []
  for j in 0..<bound[0].columns.length() {
    let t = unify_non_null(
      bound.map(b => (b.columns[j].ty, null_literal_column(b.plan, j))),
    )
    // an explicit collation in any branch labels the column (captured:
    // collation/deferred-conflicts, UNION ALL with a BIN2 branch is CS)
    let t = match union_all_collation(bound, j) {
      Some(c) => with_collation(t, c)
      None => t
    }
    columns.push(@ir.ResultColumn::{
      name: bound[0].columns[j].name,
      ty: t,
      nullable: bound.iter().any(b => b.columns[j].nullable),
      origin: SetOperation,
    })
  }
  let plans = []
  for b in bound {
    plans.push(convert_to(b, columns))
  }
  { plan: UnionAll(plans), columns, order: [], }
}

///|
fn flatten_union_all(b : @ast.QueryBody, out : Array[@ast.QueryBody]) -> Unit {
  match b {
    SetOperation(UnionAll, l, r) => {
      flatten_union_all(l, out)
      flatten_union_all(r, out)
    }
    Nested(
      {
        body,
        order_by: [],
        ctes: [],
        offset: None,
        fetch: None,
        for_clause: None,
        ..
      }
    ) => flatten_union_all(body, out)
    other => out.push(other)
  }
}

///|
/// OPTION (MAXRECURSION n); other hints are ignored.
fn max_recursion(hints : Array[@ast.QueryHint], default : Int) -> Int {
  for h in hints {
    let t = h.text.to_upper()
    if t.has_prefix("MAXRECURSION") {
      let mut v = 0
      for c in t {
        if c >= '0' && c <= '9' {
          v = v * 10 + (c.to_int() - '0'.to_int())
        }
      }
      return v
    }
  }
  default
}

///|
/// Binds a query that returns rows to the client (or creates columns:
/// SELECT INTO, views). `result_columns=false` (INSERT ... SELECT) skips
/// the 451 check for result columns without a collation.
pub fn bind_query(
  env : Env,
  q : @ast.Query,
  result_columns? : Bool = true,
) -> BoundQuery raise @types.SqlError {
  check_next_value_context(q, false)
  let env = { ..env, maxrecursion: max_recursion(q.options, env.maxrecursion), }
  match q.for_clause {
    None => {
      let bq = bind_query_inner(env, q, top_level=true)
      // deferred errors with no later error: the first one is the error
      if !env.deferred.is_empty() {
        raise env.deferred.remove(0)
      }
      // INSERT ... SELECT converts to the target columns instead (probe)
      if result_columns {
        check_result_collations(bq)
      }
      bq
    }
    Some(ForJson(mode~, root~, include_null_values~, without_array_wrapper~)) => {
      let bq = bind_query_inner(env, { ..q, for_clause: None, }, top_level=true)
      if mode is JsonAuto {
        // AUTO nests the rows of joined tables; only one source is supported
        let single = match q.body {
          Select(
            {
              from: []
              | [{ kind: Table(_, ..) | TableVar(_, ..) | Derived(_, ..), .. }],
              ..
            }
          ) => true
          _ => false
        }
        if !single || bq.columns.iter().any(c => c.name.contains(".")) {
          raise @types.not_supported("FOR JSON AUTO over joins or dotted names")
        }
      }
      for c in bq.columns {
        if c.name == "" {
          raise err(
            13605, "Column expressions and data sources without names or aliases cannot be formatted as JSON text using FOR JSON clause. Add alias to the unnamed column or table.",
          )
        }
      }
      {
        plan: ForJson(
          bq.plan,
          bq.columns,
          root~,
          include_nulls=include_null_values,
          without_array_wrapper~,
        ),
        columns: [
          {
            name: for_json_column,
            ty: NVarChar(None, env.collation),
            nullable: true,
            origin: SetOperation,
          },
        ],
        order: [],
      }
    }
    Some(_) => bind_for_xml(env, q, true)
  }
}

///|
/// `SELECT @v = expr [, ...] FROM ...`: a query whose projected values are
/// the values to store (compound operators applied), plus each target's
/// variable slot and declared type. Rows stream in order; the session
/// assigns per row (last row wins).
pub fn bind_assignment_select(
  env : Env,
  q : @ast.Query,
) -> (BoundQuery, Array[(Int, @types.SqlType)]) raise @types.SqlError {
  guard q.body is Select(s) else {
    raise @types.not_supported("assignment SELECT with set operations")
  }
  if q.for_clause is Some(_) || !q.ctes.is_empty() {
    raise @types.not_supported("assignment SELECT with WITH/FOR")
  }
  let env = { ..env, maxrecursion: max_recursion(q.options, env.maxrecursion), }
  let targets : Array[(Int, @types.SqlType)] = []
  if s.top is Some(_) && (q.offset is Some(_) || q.fetch is Some(_)) {
    raise err(
      10741,
      "A TOP can not be used in the same query or sub-query as a OFFSET.",
      state=2,
      severity=15,
    )
  }
  let bq = bind_select_query(
    env,
    s,
    q.order_by,
    q.offset,
    q.fetch,
    assign=Some(targets),
  )
  (bq, targets)
}

///|
/// Binds a scalar/EXISTS/IN subquery in the scope of `env`.
fn bind_subquery(env : Env, q : @ast.Query) -> BoundQuery raise @types.SqlError {
  check_next_value_context(q, true)
  bind_query_inner(env, q)
}

///|
/// Unifies branch types, ignoring untyped NULL literals (typed `int` by the
/// binder) unless every branch is one.
fn unify_non_null(
  tys : Array[(@types.SqlType, Bool)],
) -> @types.SqlType raise @types.SqlError {
  let typed = tys.filter(t => !t.1).map(t => t.0)
  if typed.is_empty() {
    unify_types(tys.map(t => t.0))
  } else {
    unify_types(typed)
  }
}

///|
/// Is output column `j` of a bound query a bare NULL literal?
fn null_literal_column(plan : @ir.Plan, j : Int) -> Bool {
  match plan {
    Project(_, exprs) => j < exprs.length() && exprs[j].kind is Lit(Null)
    Top(p, _, ..) | Limit(p, _, _) | Sort(p, _) | Distinct(p, _) =>
      null_literal_column(p, j)
    _ => false
  }
}

///|
/// Captured: OPENJSON `key` is nvarchar(4000) in Latin1_General_BIN2
/// (sort id 0, version 0).
let openjson_key_collation : @types.Collation = match
  @types.Collation::parse("Latin1_General_BIN2") {
  Some(c) => c
  None => @types.latin1_general_100_bin2
}
