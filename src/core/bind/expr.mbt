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
  compare_bound(env, op, a, b)
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
        BitNot => mk(BitNot(a), a.ty, a.nullable)
      }
    }
    Binary(op, l, r) => {
      let a = bind_expr(env, l)
      let b = bind_expr(env, r)
      variant_operator_check(op, a, b)
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
            mk(
              Arith(aop, a, b),
              ty,
              a.nullable || b.nullable || may_overflow(ty),
            ),
          )
        }
        BitAnd | BitOr | BitXor => {
          let ty = @types.common_type(a.ty, b.ty)
          let bop : @ir.BitOp = match op {
            BitAnd => And
            BitOr => Or
            _ => Xor
          }
          mk(
            BitOp(bop, coerce(a, ty), coerce(b, ty)),
            ty,
            a.nullable || b.nullable,
          )
        }
      }
    }
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
      let t = unify_types([a.ty] + bs.map(b => b.ty))
      let coll = resolve_collation(env, "equal to", [a] + bs)
      let a = coerce(a, t)
      let bs = bs.map(b => coerce(b, t))
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
      if a.ty is Xml || p.ty is Xml {
        raise bad_arg_type(Xml, if a.ty is Xml { 1 } else { 2 }, "like")
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
        let cond = match op {
          Some(o) => compare_bound(env, Eq, o, bind_expr(env, w.0))
          None => bind_expr(env, w.0)
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
      if vals.iter().all(is_untyped_null) {
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
      fold_case(branches, els, t, nullable)
    }
    Cast(inner, tn, try_~) => {
      let a = bind_expr(env, inner)
      let t = conversion_type(env, tn)
      conversion(a, t, try_, None)
    }
    Convert(tn, inner, style~, try_~) => {
      let a = bind_expr(env, inner)
      let t = conversion_type(env, tn)
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
      bit_expr(InQuery(a, plan, negated~, collation=coll), true)
    }
    Quantified(op, quant, x, q) => {
      let (o, _) = cmp_op(op)
      let (a, plan, coll) = compare_with_subquery(env, o, x, q)
      bit_expr(Quantified(o, a, plan, all=quant is All, collation=coll), true)
    }
    Parse(x, tn, culture~, try_~) => bind_parse(env, x, tn, culture, try_)
    AtTimeZone(x, z) => bind_at_time_zone(env, x, z)
    NextValueFor(name) =>
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
    "@@LANGUAGE" =>
      mk(Global(Language), NVarChar(Some(128), @types.default_collation), false)
    // evaluated by the session (Server.dbts)
    "@@DBTS" => mk(Call(Named("@@DBTS"), []), VarBinary(Some(8)), false)
    _ => raise @types.not_supported("global variable \{name}")
  }
}

///|
fn bind_column(
  env : Env,
  parts : Array[@ast.Ident],
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
  coerce(x, Numeric(digits, 0))
}

///|
/// Exact numeric types whose arithmetic SQL Server reports as nullable.
fn may_overflow(t : @types.SqlType) -> Bool {
  t.family() is (FInteger | FDecimal | FMoney)
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
