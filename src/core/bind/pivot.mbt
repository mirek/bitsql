///|
/// PIVOT and UNPIVOT (captured: harness/corpus/analytic/pivot*.sql,
/// unpivot.sql; rules in docs/reference/pivot.md).
///
/// PIVOT groups by every source column it does not name, and computes
/// `agg(CASE WHEN col = <value> THEN val END)` per IN value; its output is
/// sorted by the grouping columns (a stream aggregate) and its aggregates
/// never raise warning 8153. UNPIVOT emits, per source row, one row per
/// non-NULL IN column.

///|
/// Index of the source column a (possibly qualified) PIVOT/UNPIVOT column
/// name refers to, with SQL Server's 207/4104 errors.
fn pivot_column(
  env : Env,
  plan : @ir.Plan,
  cols : Array[ColumnRef],
  parts : Array[@ast.Ident],
) -> Int raise @types.SqlError {
  let e = bind_expr(env.with_source(cols, plan), {
    kind: Column(parts),
    span: parts[0].span,
  })
  match e.kind {
    Col(i) => i
    _ =>
      raise err(207, "Invalid column name '\{parts[parts.length() - 1].name}'.")
  }
}

///|
/// Types PIVOT cannot group or pivot on (488; captured: analytic/pivot-text
/// for text).
fn pivot_comparable(ty : @types.SqlType) -> Bool {
  !ty.is_lob() && !(ty is Xml)
}

///|
/// 265 (deferred) + 8156 for a generated column that repeats a grouping
/// column's name.
fn pivot_name_conflict(
  env : Env,
  name : String,
  op : String,
  alias_ : String,
) -> @types.SqlError {
  env.deferred.push(
    err(
      265,
      "The column name \"\{name}\" specified in the \{op} operator conflicts with the existing column name in the \{op} argument.",
    ),
  )
  duplicate_column(name, alias_)
}

///|
fn duplicate_column(name : String, alias_ : String) -> @types.SqlError {
  err(
    8156,
    "The column '\{name}' was specified multiple times for '\{alias_}'.",
  )
}

///|
fn bind_pivot(
  env : Env,
  src : @ast.TableRef,
  clause : @ast.PivotClause,
  alias_ : @ast.Ident,
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  let (sp, sc) = bind_table_ref(env, src)
  let q = alias_.name.to_lower()
  match clause {
    Pivot(agg~, value~, column~, values~) => {
      let vi = pivot_column(env, sp, sc, value)
      let ci = pivot_column(env, sp, sc, column)
      // the aggregate: a built-in aggregate name only
      if agg.parts.length() > 1 {
        raise err(208, "Invalid object name '\{object_text(agg)}'.", state=214)
      }
      let fname = agg.base()
      let f : @ir.AggFn = match fname.to_upper() {
        "CHECKSUM_AGG" =>
          raise err(
            406, "checksum_agg cannot be used in the PIVOT operator because it is not invariant to NULLs.",
          )
        "APPROX_COUNT_DISTINCT" => ApproxCountDistinct
        "STRING_AGG" | "GROUPING" | "GROUPING_ID" =>
          raise err(
            195,
            "'\{fname}' is not a recognized aggregate function.",
            severity=15,
          )
        u =>
          match agg_fn(u) {
            Some(f) => f
            None =>
              raise err(
                195,
                "'\{fname}' is not a recognized aggregate function.",
                severity=15,
              )
          }
      }
      let vty = sc[vi].ty
      let cty = sc[ci].ty
      let ty = agg_result_type(f, Some(vty), env)
      let groups = []
      for i in 0..<sc.length() {
        if i != vi && i != ci {
          groups.push(i)
        }
      }
      for i in groups {
        if !pivot_comparable(sc[i].ty) {
          raise err(
            488,
            "Pivot grouping columns must be comparable. The type of column \"\{sc[i].name}\" is \"\{sc[i].ty.base_name()}\", which is not comparable.",
          )
        }
      }
      if !pivot_comparable(cty) {
        raise err(
          488,
          "Pivot columns must be comparable. The type of column \"\{sc[ci].name}\" is \"\{cty.base_name()}\", which is not comparable.",
        )
      }
      // captured: COUNT(text) in PIVOT is 8117 like the plain aggregate
      if vty.is_lob() {
        raise err(
          8117,
          "Operand data type \{vty.base_name()} is invalid for \{fname.to_lower()} operator.",
        )
      }
      // output names: grouping columns, then the IN values as written
      let names : Array[String] = groups.map(i => sc[i].name)
      for i, n in names {
        for j in 0..<i {
          if same_name(names[j], n) {
            raise duplicate_column(n, alias_.name)
          }
        }
      }
      for v in values {
        if groups.iter().any(i => same_name(sc[i].name, v.name)) {
          raise pivot_name_conflict(env, v.name, "PIVOT", alias_.name)
        }
        if names.iter().any(n => same_name(n, v.name)) {
          raise duplicate_column(v.name, alias_.name)
        }
        names.push(v.name)
      }
      // IN values become constants of the pivot column's type
      let text_ty : @types.SqlType = NVarChar(Some(128), env.collation)
      let consts = values.map(v => {
        @types.cast(String(v.name), text_ty, cty) catch {
          _ => {
            env.deferred.push(
              err(
                8114,
                "Error converting data type nvarchar to \{cty.base_name()}.",
              ),
            )
            raise err(
              473,
              "The incorrect value \"\{v.name}\" is supplied in the PIVOT operator.",
            )
          }
        }
      })
      let col = @ir.Expr::{ kind: Col(ci), ty: cty, nullable: sc[ci].nullable, }
      let val = @ir.Expr::{ kind: Col(vi), ty: vty, nullable: true, }
      let aggs = consts.map(c => {
        let cond = @ir.Expr::{
          kind: Cmp(Eq, col, @ir.Expr::lit(c, cty), cty.collation()),
          ty: Bit,
          nullable: true,
        }
        @ir.AggCall::{
          func: f,
          arg: Some({
            kind: Case([(cond, val)], None),
            ty: vty,
            nullable: true,
          }),
          separator: None,
          distinct: false,
          order: [],
          ty,
        }
      })
      let keys = groups.map(i => @ir.Expr::{
        kind: Col(i),
        ty: sc[i].ty,
        nullable: sc[i].nullable,
      })
      let nk = keys.length()
      let width = nk + aggs.length()
      // without grouping columns this is GROUP BY (): no row for no input
      let grouped : @ir.Plan = if nk == 0 {
        Project(
          Aggregate(sp, [], aggs, sets=[[]]),
          Array::makei(width, j => @ir.Expr::{
            kind: Col(j),
            ty,
            nullable: true,
          }),
        )
      } else {
        Sort(
          Aggregate(sp, keys, aggs, sets=[]),
          keys.mapi((j, k) => @ir.SortKey::{
            expr: { ..k, kind: Col(j), },
            desc: false,
            collation: k.ty.collation(),
          }),
        )
      }
      // captured: APPROX_COUNT_DISTINCT in PIVOT does report 8153
      let plan : @ir.Plan = if f is ApproxCountDistinct {
        grouped
      } else {
        NoNullWarning(grouped)
      }
      let out : Array[ColumnRef] = groups.map(i => { ..sc[i], qualifier: q, })
      for v in values {
        out.push({
          untyped_null: false,
          qualifier: q,
          name: v.name,
          ty,
          nullable: true,
          origin: Aggregate,
        })
      }
      (plan, out)
    }
    Unpivot(value~, name~, columns~) => {
      // 277 for a repeated IN column, checked before resolving names
      for i, c in columns {
        for j in 0..<i {
          let a = c[c.length() - 1].name
          let b = columns[j][columns[j].length() - 1].name
          if same_name(a, b) {
            raise err(
              277,
              "The column \"\{c[c.length() - 1].name}\" is specified multiple times in the column list of the UNPIVOT operator.",
            )
          }
        }
      }
      let idx = columns.map(c => pivot_column(env, sp, sc, c))
      let ty = sc[idx[0]].ty
      for i in idx {
        if sc[i].ty != ty {
          raise err(
            8167,
            "The type of column \"\{sc[i].name}\" conflicts with the type of other columns specified in the UNPIVOT list.",
          )
        }
      }
      let keep = []
      for i in 0..<sc.length() {
        if !idx.contains(i) {
          keep.push(i)
        }
      }
      for n in [value.name, name.name] {
        if keep.iter().any(i => same_name(sc[i].name, n)) {
          raise pivot_name_conflict(env, n, "UNPIVOT", alias_.name)
        }
      }
      if same_name(value.name, name.name) {
        raise duplicate_column(name.name, alias_.name)
      }
      let out : Array[ColumnRef] = keep.map(i => { ..sc[i], qualifier: q, })
      out.push({
        untyped_null: false,
        qualifier: q,
        name: value.name,
        ty,
        nullable: idx.iter().any(i => sc[i].nullable),
        origin: SetOperation,
      })
      out.push({
        untyped_null: false,
        qualifier: q,
        name: name.name,
        ty: NVarChar(Some(128), env.collation),
        nullable: true,
        origin: SetOperation,
      })
      (Unpivot(sp, keep~, columns=idx, names=idx.map(i => sc[i].name)), out)
    }
  }
}

///|
/// Column names compare case-insensitively and ignoring trailing spaces
/// (captured: PIVOT IN ([east], [EAST ]) is 8156 for 'EAST ').
fn same_name(a : String, b : String) -> Bool {
  a.trim_end(chars=" ").to_owned().to_lower() ==
  b.trim_end(chars=" ").to_owned().to_lower()
}
