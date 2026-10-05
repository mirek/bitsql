///|
fn mk(kind : @ir.ExprKind, ty : @types.SqlType, nullable : Bool) -> @ir.Expr {
  { kind, ty, nullable, }
}

///|
fn bit_expr(kind : @ir.ExprKind, nullable : Bool) -> @ir.Expr {
  { kind, ty: Bit, nullable, }
}

///|
/// Wraps `e` in an implicit conversion to `ty` when its type differs.
pub fn coerce(
  e : @ir.Expr,
  ty : @types.SqlType,
) -> @ir.Expr raise @types.SqlError {
  if e.ty == ty {
    return e
  }
  if !@types.can_convert_implicitly(e.ty, ty) {
    raise @types.implicit_conversion_error(e.ty, ty)
  }
  { kind: Cast(e, try_=false, style=None), ty, nullable: e.nullable, }
}

///|
/// Binds `a op b` for comparisons, converting both sides to their common type.
fn compare(
  env : Env,
  op : @ir.CmpOp,
  left : @ast.Expr,
  right : @ast.Expr,
) -> @ir.Expr raise @types.SqlError {
  let a = bind_expr(env, left)
  let b = bind_expr(env, right)
  non_ansi(env, op, left, right, a, b, compare_bound(env, op, a, b))
}

///|
fn compare_bound(
  env : Env,
  op : @ir.CmpOp,
  a : @ir.Expr,
  b : @ir.Expr,
) -> @ir.Expr raise @types.SqlError {
  xml_compare_check(cmp_op_name(op), a, b)
  // captured: text/ntext/image never compare (402)
  if a.ty.is_lob() || b.ty.is_lob() {
    raise @types.lob_operator_error(a.ty, b.ty, cmp_op_name(op))
  }
  // collation precedence decides the comparison collation (or raises 468)
  let coll = resolve_collation(env, cmp_op_name(op), [a, b])
  // an untyped NULL takes the other side's type: `n = NULL` never converts
  // n to int (captured: msduck gaps-unicode-predicates equality-18)
  let (a, b) = match (is_untyped_null(a), is_untyped_null(b)) {
    (false, true) => (a, typed_null(a.ty))
    (true, false) => (typed_null(b.ty), b)
    _ => (a, b)
  }
  let t = @types.common_type(a.ty, b.ty)
  let a = coerce(a, t)
  let b = coerce(b, t)
  bit_expr(Cmp(op, a, b, coll), a.nullable || b.nullable)
}

///|
fn cmp_op(op : @ast.CmpOp) -> (@ir.CmpOp, Bool) {
  // (operator, negate result)
  match op {
    Eq => (Eq, false)
    Ne => (Ne, false)
    Lt => (Lt, false)
    Le => (Le, false)
    Gt => (Gt, false)
    Ge => (Ge, false)
    NotLt => (Ge, false)
    NotGt => (Le, false)
  }
}

///|
/// Result type of a list of branches (CASE, COALESCE, UNION columns).
pub fn unify_types(
  tys : Array[@types.SqlType],
) -> @types.SqlType raise @types.SqlError {
  // captured: a UNION ALL of rowversion columns stays timestamp (BINARY(8)
  // on the wire, msduck gaps-rowversion_identity #066); mixed branches are
  // left to common_type
  if tys.iter().all(x => x is RowVersion) {
    return RowVersion
  }
  let mut t = tys[0]
  for i in 1..<tys.length() {
    t = @types.common_type(t, tys[i])
  }
  t
}

///|
fn var_name_key(name : String) -> String {
  name.to_lower()
}

///|
pub fn bind_expr(env : Env, e : @ast.Expr) -> @ir.Expr raise @types.SqlError {
  let x = bind_expr_kind(env, e)
  check_bind_options(env, x)
  x
}

///|
fn bind_expr_kind(env : Env, e : @ast.Expr) -> @ir.Expr raise @types.SqlError {
  match e.kind {
    Null => mk(Lit(Null), Int, true)
    Default =>
      raise err(
        156,
        "Incorrect syntax near the keyword 'DEFAULT'.",
        severity=15,
      )
    IntLit(t) => int_literal(t)
    DecimalLit(t) => decimal_literal(t)
    FloatLit(t) => float_literal(t)
    MoneyLit(t) => money_literal(t)
    StrLit(s, national~) => string_literal(env, s, national)
    BinaryLit(t) => binary_literal(t, params=env.literal_params)
    Var(name) =>
      match env.vars.get(var_name_key(name)) {
        Some(v) => mk(Var(v.slot), v.ty, true)
        // a table variable used as a scalar (captured: tabletypes/
        // table-variable, state 1 class 16)
        None if env.table_var(name) is Some(_) =>
          raise err(137, "Must declare the scalar variable \"\{name}\".")
        None =>
          raise err(
            137,
            "Must declare the scalar variable \"\{name}\".",
            state=2,
            severity=15,
          )
      }
    GlobalVar(name) => bind_global(name)
    Column(parts) => bind_column_checked(env, parts)
    MethodCall(target, name, args) => bind_method_call(env, target, name, args)
    Paren(inner) => bind_expr(env, inner)
    // captured: -2147483648 and -(2147483648) are int, not numeric(10,0)
    // (analytic/generate-series, approx-checksum-agg VALUES rows)
    Unary(
      Neg,
      {
        kind: IntLit("2147483648")
        | Paren({ kind: IntLit("2147483648"), .. }),
        ..
      }
    ) => mk(Lit(Int(-2147483648)), Int, false)
    // captured: -NULL and ~NULL stay the NULL constant (untyped), while
    // -col over a derived NULL column is int, ~col and +col are not
    // (query/derived-untyped-null)
    Unary(Neg | BitNot | Plus, inner) if null_keyword(inner) =>
      mk(Lit(Null), Int, true)
    Unary(op, inner) => {
      let a = bind_expr(env, inner)
      variant_unary_check(op, a)
      match op {
        Neg => {
          // captured: msduck try-binding-error (-bit is a compile error)
          if !is_untyped_null(a) &&
            !(a.ty.family() is (FInteger | FDecimal | FMoney | FFloat)) {
            raise err(
              8117,
              "Operand data type \{a.ty.base_name()} is invalid for minus operator.",
            )
          }
          // A negated literal stays a literal so `-2147483648` keeps its type.
          mk(
            Neg(a),
            a.ty,
            a.nullable || (may_overflow(a.ty) && !(a.kind is Lit(_))),
          )
        }
        Plus => a
        // captured: ~ over a derived NULL column stays untyped (unlike -)
        BitNot if is_untyped_null(a) => a
        BitNot => mk(BitNot(a), a.ty, a.nullable)
      }
    }
    Binary(op, l, r) => binary(env, op, bind_expr(env, l), bind_expr(env, r))
    Compare(op, l, r) => {
      let (o, _) = cmp_op(op)
      compare(env, o, l, r)
    }
    Not(inner) => {
      let a = bind_expr(env, inner)
      bit_expr(Not(a), a.nullable)
    }
    And(l, r) => {
      let a = bind_expr(env, l)
      let b = bind_expr(env, r)
      bit_expr(And(a, b), a.nullable || b.nullable)
    }
    Or(l, r) => {
      let a = bind_expr(env, l)
      let b = bind_expr(env, r)
      bit_expr(Or(a, b), a.nullable || b.nullable)
    }
    IsNull(inner, negated~) =>
      // nodes() columns may be tested for NULL (captured: xml/methods)
      bit_expr(IsNull(bind_xml_target(env, inner), negated~), false)
    Between(x, lo, hi, negated~) => {
      let ge = compare(env, Ge, x, lo)
      let le = compare(env, Le, x, hi)
      let both = bit_expr(And(ge, le), ge.nullable || le.nullable)
      if negated {
        bit_expr(Not(both), both.nullable)
      } else {
        both
      }
    }
    InList(x, items, negated~) => {
      let a = bind_expr(env, x)
      let bs = items.map(i => bind_expr(env, i))
      // captured: text IN ('abc') is 402 "… in the equal to operator"
      for b in bs {
        xml_compare_check("equal to", a, b)
        if a.ty.is_lob() || b.ty.is_lob() {
          raise @types.lob_operator_error(a.ty, b.ty, "equal to")
        }
      }
      // untyped NULL items take no part in the type (captured: msduck
      // gaps-unicode-predicates membership-4/5, n IN (N'x', NULL))
      let typed = bs.filter(b => !is_untyped_null(b))
      let t = unify_types([a.ty] + typed.map(b => b.ty))
      let coll = resolve_collation(env, "equal to", [a] + bs)
      let a = coerce(a, t)
      let bs = bs.map(b => {
        if is_untyped_null(b) {
          typed_null(t)
        } else {
          coerce(b, t)
        }
      })
      match non_ansi_in_list(env, x, items, a, bs, coll, negated) {
        Some(e) => return e
        None => ()
      }
      let nullable = a.nullable || bs.iter().any(b => b.nullable)
      bit_expr(InList(a, bs, negated~, collation=coll), nullable)
    }
    Like(x, pattern, escape~, negated~) => {
      let a = bind_expr(env, x)
      let p = bind_expr(env, pattern)
      let esc = match escape {
        Some(e) => Some(bind_expr(env, e))
        None => None
      }
      variant_like_check(a, p, esc)
      if a.ty is (Xml | Json) || p.ty is (Xml | Json) {
        let (t, n) = if a.ty is (Xml | Json) { (a.ty, 1) } else { (p.ty, 2) }
        raise bad_arg_type(t, n, "like")
      }
      // captured: image LIKE '%b%' is 8116 for the pattern (argument 2)
      if a.ty is Image || p.ty is Image {
        raise err(
          8116,
          "Argument data type \{(if a.ty is Image { p.ty } else { a.ty }).base_name()} is invalid for argument 2 of like function.",
        )
      }
      bit_expr(
        Like(
          a,
          p,
          escape=esc,
          negated~,
          collation=resolve_collation(env, "like", [a, p]),
        ),
        a.nullable || p.nullable,
      )
    }
    Case(operand~, whens~, else_~) => {
      let op = match operand {
        Some(o) => Some(bind_expr(env, o))
        None => None
      }
      let branches = []
      for w in whens {
        let cond = match (op, operand) {
          (Some(o), Some(oa)) => {
            let b = bind_expr(env, w.0)
            non_ansi(env, Eq, oa, w.0, o, b, compare_bound(env, Eq, o, b))
          }
          _ => bind_expr(env, w.0)
        }
        branches.push((cond, bind_expr(env, w.1)))
      }
      let els = match else_ {
        Some(x) => Some(bind_expr(env, x))
        None => None
      }
      let vals = branches.map(b => b.1)
      if els is Some(x) {
        vals.push(x)
      }
      // captured: CASE whose results are all the NULL constant is 8133
      // (msduck count-null-compilation #032)
      let asts = whens.map(w => w.1)
      if else_ is Some(x) {
        asts.push(x)
      }
      if all_null_constants(vals, asts) {
        raise err(
          8133, "At least one of the result expressions in a CASE specification must be an expression other than the NULL constant.",
        )
      }
      // untyped NULL branches do not take part; integer literals next to a
      // decimal count as numeric(digits, 0) (captured: traps/
      // metadata-not-from-values CASE .. 1 ELSE 2.5 is numeric(2,1))
      let t = unify_args(vals)
      let nullable = els is None ||
        branches.iter().any(b => b.1.nullable) ||
        (els is Some(x) && x.nullable)
      adopt_collation(env, fold_case(branches, els, t, nullable))
    }
    Cast(inner, tn, try_~) => {
      let a = bind_expr(env, inner)
      let t = keep_collation(a, conversion_type(env, tn))
      conversion(a, t, try_, None)
    }
    Convert(tn, inner, style~, try_~) => {
      let a = bind_expr(env, inner)
      let t = keep_collation(a, conversion_type(env, tn))
      let st = match style {
        None => None
        Some({ kind: IntLit(s), .. }) => Some(parse_style(s))
        Some(x) => {
          // a run-time style (captured: DECLARE @s int = 112; CONVERT(..,
          // @s) works): converted when evaluated
          let sx = bind_expr(env, x)
          if !(sx.ty.family() is FInteger) && !(sx.kind is Lit(Null)) {
            // captured: varchar, bit and decimal style variables are 8116
            // state 1; bigint works
            raise err(
              8116,
              "Argument data type \{sx.ty.base_name()} is invalid for argument 3 of convert function.",
            )
          }
          let c = conversion(a, t, try_, None)
          if c.kind is Cast(_, ..) {
            return {
              ..c,
              kind: Call(
                Named(if try_ { "TRY_CONVERT_STYLE" } else { "CONVERT_STYLE" }),
                [a, sx],
              ),
            }
          }
          return c
        }
      }
      conversion(a, t, try_, st)
    }
    Collate(inner, name) => {
      let a = bind_expr(env, inner)
      let c = match @types.Collation::parse(name.name) {
        Some(c) => c
        None => raise @types.unknown_collation_error(name.name)
      }
      let ty : @types.SqlType = match a.ty {
        Char(n, _) => Char(n, c)
        VarChar(n, _) => VarChar(n, c)
        NChar(n, _) => NChar(n, c)
        NVarChar(n, _) => NVarChar(n, c)
        // captured: text/ntext take COLLATE (image is 447)
        Text(_) => Text(c)
        NText(_) => NText(c)
        other =>
          raise err(
            447,
            "Expression type \{other.base_name()} is invalid for COLLATE clause.",
            // captured: msduck collation-precedence #016
            state=0,
          )
      }
      { kind: Collate(a), ty, nullable: a.nullable, }
    }
    Call(call) => bind_call(env, call)
    Exists(q) => bit_expr(Exists(bind_subquery(env, q).plan), false)
    Subquery(q) => {
      let (plan, c) = single_column(env, q)
      // captured: scalar subqueries are nullable computed columns (flags 33)
      mk(Subquery(plan), c.ty, true)
    }
    InQuery(x, q, negated~) => {
      let (a, plan, coll) = compare_with_subquery(env, Eq, x, q)
      if !env.ansi_nulls {
        return non_ansi_subquery(Eq, a, plan, coll, all=false, negated~)
      }
      bit_expr(InQuery(a, plan, negated~, collation=coll), true)
    }
    Quantified(op, quant, x, q) => {
      let (o, _) = cmp_op(op)
      let (a, plan, coll) = compare_with_subquery(env, o, x, q)
      if !env.ansi_nulls && o is (Eq | Ne) {
        return non_ansi_subquery(
          o,
          a,
          plan,
          coll,
          all=quant is All,
          negated=false,
        )
      }
      bit_expr(Quantified(o, a, plan, all=quant is All, collation=coll), true)
    }
    Parse(x, tn, culture~, try_~) => bind_parse(env, x, tn, culture, try_)
    AtTimeZone(x, z) => bind_at_time_zone(env, x, z)
    NextValueFor(name, _) =>
      match (env.catalog.sequence)(name) {
        // evaluated by the session (Ctx::ext); never folded
        Some((key, ty)) =>
          mk(
            Call(Named("NEXT VALUE FOR"), [
              mk(
                Lit(String(key)),
                VarChar(Some(128), @types.default_collation),
                false,
              ),
            ]),
            ty,
            false,
          )
        None =>
          raise @types.sql_error(
            208,
            "Invalid object name '\{name.parts.map(p => p.name).join(".")}'.",
            state=211,
          )
      }
  }
}

///|
fn parse_style(s : String) -> Int {
  let mut v = 0
  for c in s {
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  v
}

///|
fn conversion(
  a : @ir.Expr,
  t : @types.SqlType,
  try_ : Bool,
  style : Int?,
) -> @ir.Expr raise @types.SqlError {
  // a bare NULL converts to any type (CAST(NULL AS date)); a typed NULL
  // keeps its type's rules (captured: CONVERT(varchar(max), CAST(NULL AS
  // image)) is 529, msduck concat-text-conversion#148)
  if a.kind is Lit(Null) && a.ty is Int && !(t is Int) {
    return { kind: Lit(Null), ty: t, nullable: true, }
  }
  if !@types.can_convert_explicitly(a.ty, t) {
    raise @types.explicit_conversion_error(a.ty, t)
  }
  variant_constant_cast_check(a, t)
  // Captured: CAST/CONVERT results are always nullable (flags 33).
  { kind: Cast({ ..a, }, try_~, style~), ty: t, nullable: true, }
}

///|
fn bind_global(name : String) -> @ir.Expr raise @types.SqlError {
  let int_ = (g : @ir.Global) => mk(Global(g), Int, false)
  match name.to_upper() {
    "@@ROWCOUNT" => int_(RowCount)
    "@@ERROR" => int_(Error)
    "@@TRANCOUNT" => int_(TranCount)
    "@@FETCH_STATUS" => int_(FetchStatus)
    "@@NESTLEVEL" => int_(NestLevel)
    "@@OPTIONS" => int_(Options)
    "@@IDENTITY" => mk(Global(Identity), Numeric(38, 0), true)
    "@@SPID" => mk(Global(Spid), SmallInt, false)
    "@@DATEFIRST" => mk(Global(DateFirst), TinyInt, true)
    "@@TEXTSIZE" => int_(TextSize)
    "@@LOCK_TIMEOUT" => int_(LockTimeout)
    "@@MAX_PRECISION" => mk(Global(MaxPrecision), TinyInt, false)
    "@@PROCID" => int_(ProcId)
    "@@CURSOR_ROWS" => int_(CursorRows)
    "@@VERSION" =>
      mk(Global(Version), NVarChar(Some(300), @types.default_collation), false)
    "@@SERVERNAME" =>
      mk(
        Global(ServerName),
        NVarChar(Some(128), @types.default_collation),
        true,
      )
    "@@SERVICENAME" =>
      mk(
        Global(ServiceName),
        NVarChar(Some(128), @types.default_collation),
        true,
      )
    // captured: nvarchar(128) nullable, @@LANGID smallint NOT NULL
    // (settings/language)
    "@@LANGUAGE" =>
      mk(Global(Language), NVarChar(Some(128), @types.default_collation), true)
    // evaluated by the session (Server.dbts, the session language)
    "@@DBTS" => mk(Call(Named("@@DBTS"), []), VarBinary(Some(8)), false)
    "@@LANGID" => mk(Call(Named("@@LANGID"), []), SmallInt, false)
    _ => raise @types.not_supported("global variable \{name}")
  }
}

///|
/// The NULL keyword, possibly parenthesized.
fn null_keyword(e : @ast.Expr) -> Bool {
  match e.kind {
    Null => true
    Paren(x) => null_keyword(x)
    _ => false
  }
}

///|
/// A bare (possibly parenthesized) column reference.
fn bare_column(e : @ast.Expr) -> Array[@ast.Ident]? {
  match e.kind {
    Column(parts) => Some(parts)
    Paren(x) => bare_column(x)
    _ => None
  }
}

///|
/// CASE / IIF results (8133) and COALESCE arguments (4127) that are all
/// the NULL constant. A bare reference to a derived table's NULL column
/// binds as the untyped literal but does not count here, while an
/// expression over one does (captured: query/derived-untyped-null,
/// CASE WHEN .. THEN s.o END is int, THEN ISNULL(s.o, NULL) END is 8133).
fn all_null_constants(bound : Array[@ir.Expr], asts : Array[@ast.Expr]) -> Bool {
  bound.iter().all(is_untyped_null) &&
  !asts.iter().any(a => bare_column(a) is Some(_))
}

///|
fn bind_column(
  env : Env,
  parts : Array[@ast.Ident],
  raw? : Bool = false,
) -> @ir.Expr raise @types.SqlError {
  let name = parts[parts.length() - 1].name.to_lower()
  let qualifier = if parts.length() >= 2 {
    parts[parts.length() - 2].name.to_lower()
  } else {
    ""
  }
  let mut scope : Env? = Some(env)
  let mut depth = 0
  while scope is Some(s) {
    let mut found = -1
    for i, c in s.columns {
      if c.name.to_lower() == name &&
        (qualifier == "" || c.qualifier == qualifier) {
        if found >= 0 {
          raise err(
            209,
            "Ambiguous column name '\{parts[parts.length() - 1].name}'.",
          )
        }
        found = i
      }
    }
    if found >= 0 {
      let c = s.columns[found]
      // a derived table's NULL constant column reads as the untyped NULL
      // literal (`raw`: the column itself, for name lookups)
      if c.untyped_null && !raw {
        return mk(Lit(Null), Int, true)
      }
      let kind : @ir.ExprKind = if depth == 0 {
        Col(found)
      } else {
        OuterCol(depth, found)
      }
      return mk(kind, c.ty, c.nullable)
    }
    // A qualifier naming a table of this scope binds here even when the
    // column is missing: 207, and outer tables of the same name are hidden
    // (captured: output/scoping).
    if qualifier != "" && s.columns.iter().any(c => c.qualifier == qualifier) {
      raise err(207, "Invalid column name '\{parts[parts.length() - 1].name}'.")
    }
    scope = s.outer
    depth += 1
  }
  if parts.length() >= 2 {
    let text = parts.map(p => p.name).join(".")
    raise err(4104, "The multi-part identifier \"\{text}\" could not be bound.")
  }
  raise err(207, "Invalid column name '\{parts[0].name}'.")
}

///|
/// A subquery that must return one column (116 otherwise).
fn single_column(
  env : Env,
  q : @ast.Query,
) -> (@ir.Plan, @ir.ResultColumn) raise @types.SqlError {
  let bq = bind_subquery(env, q)
  if bq.columns.length() != 1 {
    raise err(
      116, "Only one expression can be specified in the select list when the subquery is not introduced with EXISTS.",
    )
  }
  (bq.plan, bq.columns[0])
}

///|
/// `x IN (subquery)` / `x op ANY (subquery)`: both sides converted to their
/// common type.
fn compare_with_subquery(
  env : Env,
  op : @ir.CmpOp,
  x : @ast.Expr,
  q : @ast.Query,
) -> (@ir.Expr, @ir.Plan, @types.Collation?) raise @types.SqlError {
  let a = bind_expr(env, x)
  let (plan, c) = single_column(env, q)
  let t = @types.common_type(a.ty, c.ty)
  let a = coerce(a, t)
  let plan : @ir.Plan = if c.ty == t {
    plan
  } else {
    Project(plan, [coerce(mk(Col(0), c.ty, c.nullable), t)])
  }
  let coll = resolve_collation(env, cmp_op_name(op), [
    a,
    mk(Col(0), c.ty, c.nullable),
  ])
  (a, plan, coll)
}

///|
/// An integer literal (possibly negated or parenthesized) meeting a
/// decimal operand in arithmetic is typed numeric(digits, 0) (captured
/// probes, corpus collation/expression-metadata: 1.5*2 is numeric(4,1),
/// 1.5*20 numeric(5,1), 1.5+-2 numeric(3,1), 2/2147483649 numeric(12,11),
/// but 1.5*CAST(2 AS int) and 2.5*@@TRANCOUNT numeric(13,1)).
fn int_literal_as_numeric(
  x : @ir.Expr,
  other : @ir.Expr,
) -> @ir.Expr raise @types.SqlError {
  // folded arithmetic (`1+1`) is a nullable literal and keeps int
  guard other.ty is (Decimal(_, _) | Numeric(_, _)) &&
    x.ty is Int &&
    !x.nullable else {
    return x
  }
  let v = match x.kind {
    Lit(Int(v)) => v
    Neg({ kind: Lit(Int(v)), .. }) => v
    _ => return x
  }
  let digits = @cmp.maximum(1, v.abs().to_string().length())
  // it takes the other operand's name: `@decimal + 1` stays decimal while
  // numeric beside decimal makes numeric (captured: query/top-fetch-bigint
  // probe)
  coerce(
    x,
    if other.ty is Decimal(_, _) {
      Decimal(digits, 0)
    } else {
      Numeric(digits, 0)
    },
  )
}

///|
/// Exact numeric types whose arithmetic SQL Server reports as nullable.
fn may_overflow(t : @types.SqlType) -> Bool {
  t.family() is (FInteger | FDecimal | FMoney)
}

///|
/// CAST/CONVERT of character data to a character type keeps the input's
/// collation (SQL Server: "the output has the same collation and collation
/// label as the input"; captured: settings/utf8, CAST(x COLLATE …_UTF8 AS
/// varchar(20)) is UTF-8).
fn keep_collation(a : @ir.Expr, t : @types.SqlType) -> @types.SqlType {
  match (a.ty.collation(), t.collation()) {
    (Some(c), Some(_)) => t.with_collation(c)
    _ => t
  }
}

///|
/// The target type of CAST/CONVERT: only system types (captured: an alias
/// or unknown type is 243, state 2 when a user type of that name exists).
fn conversion_type(
  env : Env,
  tn : @ast.TypeName,
) -> @types.SqlType raise @types.SqlError {
  resolve_type(tn, Conversion, env.collation) catch {
    @types.SqlError(number=2715, ..) => {
      let written = match tn.schema {
        Some(s) => s.name + "." + tn.name
        None => tn.name
      }
      raise err(
        243,
        "Type \{written} is not a defined system type.",
        state=if (env.catalog.user_type)(tn) { 2 } else { 1 },
      )
    }
    e => raise e
  }
}

///|
/// `a op b` over bound operands (arithmetic, string `+`, bitwise).
fn binary(
  env : Env,
  op : @ast.BinOp,
  a : @ir.Expr,
  b : @ir.Expr,
) -> @ir.Expr raise @types.SqlError {
  // captured: NULL + NULL (also over derived NULL columns) stays the
  // NULL constant: untyped, assignable anywhere, 8133 in a CASE
  if op is (Add | Sub | Mul | Div | Mod) &&
    is_untyped_null(a) &&
    is_untyped_null(b) {
    return mk(Lit(Null), Int, true)
  }
  if !(op is (BitAnd | BitOr | BitXor)) {
    variant_operator_check(op, a, b)
  }
  // an untyped NULL next to a string concatenates as varchar(1)
  // (captured probes: N'a'+NULL is nvarchar(2), CAST('a' AS CHAR(2))+NULL
  // varchar(3); msduck character-concat #022)
  let null_str = (x : @ir.Expr, other : @ir.Expr) => {
    if op is Add && is_untyped_null(x) && other.ty.family() == FString {
      mk(Lit(Null), VarChar(Some(1), env.collation), true)
    } else {
      x
    }
  }
  let (a, b) = (null_str(a, b), null_str(b, a))
  let (a, b) = if op is (Add | Sub | Mul | Div | Mod) {
    (int_literal_as_numeric(a, b), int_literal_as_numeric(b, a))
  } else {
    (a, b)
  }
  match op {
    Add | Sub | Mul | Div | Mod => {
      let aop : @types.ArithOp = match op {
        Add => Add
        Sub => Sub
        Mul => Mul
        Div => Div
        _ => Mod
      }
      // captured: text + 'x' is 402 "… incompatible in the add operator"
      if a.ty.is_lob() || b.ty.is_lob() {
        raise @types.lob_operator_error(a.ty, b.ty, aop.name())
      }
      let ty = @types.arith_result_type(aop, a.ty, b.ty)
      // captured: exact-numeric arithmetic is nullable even over NOT
      // NULL operands (overflow may yield NULL); float and string `+`
      // are not (query/README probe: id + 1 IntN 33, f * 2 Float 32)
      fold_arith(
        mk(Arith(aop, a, b), ty, a.nullable || b.nullable || may_overflow(ty)),
      )
    }
    BitAnd | BitOr | BitXor => {
      let ty = bitwise_type(op, a, b)
      let bop : @ir.BitOp = match op {
        BitAnd => And
        BitOr => Or
        _ => Xor
      }
      mk(BitOp(bop, coerce(a, ty), coerce(b, ty)), ty, a.nullable || b.nullable)
    }
  }
}

///|
/// The value `x op= rhs` stores: `x op rhs`, bound exactly like the binary
/// expression (captured: dml/compound-assignment; result type, bitwise
/// operators, string concatenation, 402 for varbinary |= varbinary).
pub fn compound_assignment(
  env : Env,
  op : @ast.AssignOp,
  current : @ir.Expr,
  rhs : @ir.Expr,
) -> @ir.Expr raise @types.SqlError {
  let bop : @ast.BinOp = match op {
    Assign => return rhs
    AddAssign => Add
    SubAssign => Sub
    MulAssign => Mul
    DivAssign => Div
    ModAssign => Mod
    AndAssign => BitAnd
    OrAssign => BitOr
    XorAssign => BitXor
  }
  binary(env, bop, current, rhs)
}

///|
/// Result type of `a & b` / `a | b` / `a ^ b` (captured probes, dml/
/// compound-assignment): one operand must be an integer type (bit..bigint);
/// the other may also be binary/varbinary (rowversion), character or the
/// untyped NULL, and the result is the integer operand's type (the higher
/// one when both are integers). Otherwise 402 naming both types, or 8117
/// naming the left one when neither is even a possible bitwise operand.
fn bitwise_type(
  op : @ast.BinOp,
  a : @ir.Expr,
  b : @ir.Expr,
) -> @types.SqlType raise @types.SqlError {
  let is_int = (e : @ir.Expr) => {
    !is_untyped_null(e) && e.ty is (Bit | TinyInt | SmallInt | Int | BigInt)
  }
  let operand = (e : @ir.Expr) => {
    is_untyped_null(e) ||
    e.ty
    is (Bit
    | TinyInt
    | SmallInt
    | Int
    | BigInt
    | Binary(_)
    | VarBinary(_)
    | RowVersion
    | Char(_, _)
    | VarChar(_, _)
    | NChar(_, _)
    | NVarChar(_, _))
  }
  let name = (e : @ir.Expr) => {
    if is_untyped_null(e) {
      "NULL"
    } else {
      e.ty.clash_name()
    }
  }
  let sym = match op {
    BitAnd => "&"
    BitOr => "|"
    _ => "^"
  }
  match (is_int(a), is_int(b)) {
    (true, true) => @types.common_type(a.ty, b.ty)
    (true, false) if operand(b) => a.ty
    (false, true) if operand(a) => b.ty
    _ if !operand(a) && !operand(b) =>
      raise @types.sql_error(
        8117,
        "Operand data type \{name(a)} is invalid for '\{sym}' operator.",
      )
    _ =>
      raise @types.sql_error(
        402,
        "The data types \{name(a)} and \{name(b)} are incompatible in the '\{sym}' operator.",
      )
  }
}
