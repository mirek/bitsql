// Collation precedence (coercibility), derived from captures; rules and
// evidence in docs/reference/result-metadata.md "Collation precedence".

///|
/// Collation coercibility (SQL Server "collation precedence").
priv enum Coercibility {
  Explicit(@types.Collation)
  Implicit(@types.Collation)
  Default
  /// Two different implicit collations met in an operator that does not
  /// need a collation (`+`, CONCAT, CASE, UNION ALL): usable as a value,
  /// but a collation-sensitive operation on it raises 4191 and a result
  /// column raises 451. Fields: the collations in message order (later
  /// operand first) and the operator's name for 451.
  NoCollation(@types.Collation, @types.Collation, String)
}

///|
fn is_string(t : @types.SqlType) -> Bool {
  t.family() == FString
}

///|
/// Coercibility of a column reference: what the column's defining
/// expression had when the column comes from a derived table, CTE or view
/// (captured: msduck collation-precedence #000/#001), else implicit.
type ColumnCoercibility = (Int, Int, @types.SqlType) -> Coercibility

///|
fn implicit_of(t : @types.SqlType) -> Coercibility {
  match t.collation() {
    Some(c) => Implicit(c)
    None => Default
  }
}

///|
/// Coercibility of `e` in binding environment `env`.
fn coercibility(env : Env, e : @ir.Expr) -> Coercibility {
  coercibility_in(e, (depth, i, t) => env_column(env, depth, i, t))
}

///|
fn env_column(
  env : Env,
  depth : Int,
  i : Int,
  t : @types.SqlType,
) -> Coercibility {
  let mut s = env
  for _ in 0..<depth {
    match s.outer {
      Some(o) => s = o
      None => return implicit_of(t)
    }
  }
  match s.from_plan {
    Some(p) => plan_column(p, i, t)
    None => implicit_of(t)
  }
}

///|
/// Coercibility of output column `j` (of type `t`) of a plan. Base table
/// columns are implicit; projections take their expression's.
fn plan_column(plan : @ir.Plan, j : Int, t : @types.SqlType) -> Coercibility {
  if !is_string(t) {
    return Default
  }
  match plan {
    Project(p, exprs) =>
      if j < exprs.length() {
        coercibility_in(exprs[j], (depth, i, ty) => {
          if depth == 0 {
            plan_column(p, i, ty)
          } else {
            implicit_of(ty)
          }
        })
      } else {
        implicit_of(t)
      }
    Filter(p, _)
    | Sort(p, _)
    | Limit(p, _, _)
    | Distinct(p, _)
    | Top(p, _, ..)
    | ForJson(p, _, ..) => plan_column(p, j, t)
    Join(_, l, r, _, left_width~, ..) =>
      if j < left_width {
        plan_column(l, j, t)
      } else {
        plan_column(r, j - left_width, t)
      }
    UnionAll(plans) => {
      let mut c = Default
      for p in plans {
        c = combine(c, plan_column(p, j, t), "UNION ALL") catch { _ => c }
      }
      c
    }
    SetOp(_, l, r, _) =>
      combine(plan_column(l, j, t), plan_column(r, j, t), "UNION") catch {
        _ => implicit_of(t)
      }
    Values(_) => Default
    Aggregate(p, keys, _, ..) =>
      if j < keys.length() {
        coercibility_in(keys[j], (depth, i, ty) => {
          if depth == 0 {
            plan_column(p, i, ty)
          } else {
            implicit_of(ty)
          }
        })
      } else {
        implicit_of(t)
      }
    _ => implicit_of(t)
  }
}

///|
/// An untyped NULL literal, possibly wrapped in the implicit conversion
/// ISNULL adds.
fn is_untyped_null_arg(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(Null) => e.ty is Int
    Cast(a, ..) => a.kind is Lit(Null) && a.ty is Int
    _ => false
  }
}

///|
fn coercibility_in(e : @ir.Expr, col : ColumnCoercibility) -> Coercibility {
  if !is_string(e.ty) {
    return Default
  }
  match e.kind {
    Collate(_) =>
      match e.ty.collation() {
        Some(c) => Explicit(c)
        None => Default
      }
    Col(i) => col(0, i, e.ty)
    OuterCol(d, i) => col(d, i, e.ty)
    // a string-to-string conversion keeps the input's collation label
    Cast(a, ..) =>
      if is_string(a.ty) {
        coercibility_in(a, col)
      } else {
        Default
      }
    Case(branches, els) => {
      let mut c = Default
      for b in branches {
        c = combine(c, coercibility_in(b.1, col), "CASE") catch { _ => c }
      }
      if els is Some(x) {
        c = combine(c, coercibility_in(x, col), "CASE") catch { _ => c }
      }
      c
    }
    Concat(a, b) | Arith(_, a, b) =>
      combine(coercibility_in(a, col), coercibility_in(b, col), "add") catch {
        _ => Default
      }
    // captured (msduck collation-functions #001-#003, #042-#045): ISNULL
    // takes its first argument's collation, the second's only when the
    // first is an untyped NULL
    Call(IsNull, args) if args.length() == 2 =>
      if is_untyped_null_arg(args[0]) {
        coercibility_in(args[1], col)
      } else {
        coercibility_in(args[0], col)
      }
    Call(f, args) => {
      let label = match f {
        // captured: "CHOOSE operator", "concat operator"
        Named("CHOOSE") => "CHOOSE"
        Named(n) => n.to_lower()
        _ => "function"
      }
      let mut c = Default
      for a in args {
        if is_string(a.ty) {
          c = combine(c, coercibility_in(a, col), label) catch { _ => c }
        }
      }
      c
    }
    Subquery(plan) => plan_column(plan, 0, e.ty)
    _ => Default
  }
}

///|
priv suberror ExplicitConflict {
  ExplicitConflict(@types.Collation, @types.Collation)
}

///|
/// Combines the coercibility of operand `a` with that of a later operand
/// `b` in operator `op` (named in 451 messages).
fn combine(
  a : Coercibility,
  b : Coercibility,
  op : String,
) -> Coercibility raise ExplicitConflict {
  match (a, b) {
    (Explicit(x), Explicit(y)) =>
      if x == y {
        a
      } else {
        raise ExplicitConflict(x, y)
      }
    (Explicit(_), _) => a
    (_, Explicit(_)) => b
    (NoCollation(_, _, _), _) => a
    (_, NoCollation(_, _, _)) => b
    (Implicit(x), Implicit(y)) => if x == y { a } else { NoCollation(y, x, op) }
    (Implicit(_), Default) => a
    (Default, Implicit(_)) => b
    (Default, Default) => Default
  }
}

///|
fn conflict_error(
  x : @types.Collation,
  y : @types.Collation,
  op : String,
) -> @types.SqlError {
  @types.sql_error(
    468,
    "Cannot resolve the collation conflict between \"\{x.name}\" and \"\{y.name}\" in the \{op} operation.",
    state=9,
  )
}

///|
/// The collation a collation-sensitive operation uses. Raises 468 when two
/// different explicit collations meet, or two different implicit ones meet
/// directly in this operation (later operand named first, captured: msduck
/// collation-functions "between CS_AS and BIN2" for BIN2 = CS_AS), and 4191
/// "Cannot resolve collation conflict for <op> operation." when an operand
/// already has no collation (a CASE or `+` over different implicit
/// collations; captured: msduck bin2-comparisons *-deferred,
/// collation-sensitive *-deferred).
fn resolve_collation(
  env : Env,
  op : String,
  operands : Array[@ir.Expr],
) -> @types.Collation? raise @types.SqlError {
  if !operands.iter().any(o => is_string(o.ty)) {
    return None
  }
  let mut c = Default
  let mut deferred = false
  for o in operands {
    if is_string(o.ty) {
      let oc = coercibility(env, o)
      if oc is NoCollation(_, _, _) {
        deferred = true
      }
      c = combine(c, oc, op) catch {
        ExplicitConflict(x, y) => raise conflict_error(y, x, op)
      }
    }
  }
  match c {
    Explicit(x) | Implicit(x) => Some(x)
    Default => Some(env.collation)
    NoCollation(x, y, _) =>
      if deferred {
        raise @types.sql_error(
          4191,
          "Cannot resolve collation conflict for \{op} operation.",
          state=9,
        )
      } else {
        raise conflict_error(x, y, op)
      }
  }
}

///|
/// 4191 when a string argument has no collation and no explicit collation
/// among the arguments repairs it (captured probes: LEN(a+b), UPPER(a+b),
/// LEFT(CASE .. END, 1) over two implicit collations; msduck
/// collation-sensitive #002/#003). Conflicts between the arguments
/// themselves are the function binder's (468, collate_args).
fn check_deferred_collation(
  env : Env,
  op : String,
  args : Array[@ir.Expr],
) -> Unit raise @types.SqlError {
  let mut deferred = false
  let mut c = Default
  for a in args {
    if is_string(a.ty) {
      let ac = coercibility(env, a)
      if ac is NoCollation(_, _, _) {
        deferred = true
      }
      c = combine(c, ac, op) catch { _ => return }
    }
  }
  if deferred && !(c is Explicit(_)) {
    raise @types.sql_error(
      4191,
      "Cannot resolve collation conflict for \{op} operation.",
      state=9,
    )
  }
}

///|
/// 451 for a result column whose value has no collation (captured probes,
/// docs/reference/result-metadata.md): "Cannot resolve collation conflict
/// between "<later>" and "<earlier>" in <op> operator occurring in SELECT
/// statement column <n>." SQL Server reports every such column; bitsql
/// raises the first.
fn check_result_collations(bq : BoundQuery) -> Unit raise @types.SqlError {
  for j, c in bq.columns {
    if plan_column(bq.plan, j, c.ty) is NoCollation(x, y, op) {
      raise @types.sql_error(
        451,
        "Cannot resolve collation conflict between \"\{x.name}\" and \"\{y.name}\" in \{op} operator occurring in SELECT statement column \{j + 1}.",
        state=1,
      )
    }
  }
}

///|
/// Collation of column `j` of a UNION / INTERSECT / EXCEPT (collation
/// sensitive, unlike UNION ALL): 468 "in the UNION operation" for two
/// different implicit or explicit collations (captured: msduck
/// collation-precedence #018, probes for INTERSECT/EXCEPT).
fn set_op_collation(
  env : Env,
  op : String,
  l : BoundQuery,
  r : BoundQuery,
  j : Int,
) -> @types.Collation? raise @types.SqlError {
  let lt = l.columns[j].ty
  let rt = r.columns[j].ty
  if !is_string(lt) || !is_string(rt) {
    return None
  }
  let a = plan_column(l.plan, j, lt)
  let b = plan_column(r.plan, j, rt)
  let deferred = a is NoCollation(_, _, _) || b is NoCollation(_, _, _)
  let c = combine(a, b, op) catch {
    ExplicitConflict(x, y) => raise conflict_error(y, x, op)
  }
  match c {
    Explicit(x) | Implicit(x) => Some(x)
    Default => Some(env.collation)
    NoCollation(x, y, _) =>
      if deferred {
        raise @types.sql_error(
          4191,
          "Cannot resolve collation conflict for \{op} operation.",
          state=9,
        )
      } else {
        raise conflict_error(x, y, op)
      }
  }
}

///|
/// The collation UNION ALL column `j` carries: the explicit or common
/// implicit one of its branches (None when no branch is a string or the
/// branches have no common collation; 451 then comes from
/// `check_result_collations`).
fn union_all_collation(parts : Array[BoundQuery], j : Int) -> @types.Collation? {
  let mut c = Default
  for p in parts {
    let t = p.columns[j].ty
    if is_string(t) {
      c = combine(c, plan_column(p.plan, j, t), "UNION ALL") catch {
        _ => return None
      }
    }
  }
  match c {
    Explicit(x) | Implicit(x) => Some(x)
    _ => None
  }
}

///|
fn cmp_op_name(op : @ir.CmpOp) -> String {
  match op {
    Eq => "equal to"
    Ne => "not equal to"
    Lt => "less than"
    Le => "less than or equal to"
    Gt => "greater than"
    Ge => "greater than or equal to"
  }
}

///|
/// The collation label of a function result over string arguments (CONCAT):
/// the combined explicit/implicit collation, else the database default
/// (captured: msduck collation-functions #006, #040).
fn label_collation(env : Env, args : Array[@ir.Expr]) -> @types.Collation {
  let mut c = Default
  for a in args {
    if is_string(a.ty) {
      c = combine(c, coercibility(env, a), "concat") catch {
        _ => return env.collation
      }
    }
  }
  match c {
    Explicit(x) | Implicit(x) => x
    _ => env.collation
  }
}

///|
/// 456 when a value with no collation (two implicit collations met) is
/// converted to sql_variant (captured: msduck collation-functions #038,
/// #046, #050, #052).
fn variant_collation_check(
  env : Env,
  e : @ir.Expr,
) -> Unit raise @types.SqlError {
  if coercibility(env, e) is NoCollation(x, y, op) {
    raise @types.sql_error(
      456,
      "Implicit conversion of \{e.ty.base_name()} value to sql_variant cannot be performed because the resulting collation is unresolved due to collation conflict between \"\{x.name}\" and \"\{y.name}\" in \{op} operator.",
    )
  }
}
