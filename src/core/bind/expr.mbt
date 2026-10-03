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
    BinaryLit(t) => binary_literal(t)
    Var(name) =>
      match env.vars.get(var_name_key(name)) {
        Some(v) => mk(Var(v.slot), v.ty, true)
        None =>
          raise err(
            137,
            "Must declare the scalar variable \"\{name}\".",
            state=2,
            severity=15,
          )
      }
    GlobalVar(name) => bind_global(name)
    Column(parts) => bind_column(env, parts)
    Paren(inner) => bind_expr(env, inner)
    Unary(op, inner) => {
      let a = bind_expr(env, inner)
      match op {
        Neg =>
          // A negated literal stays a literal so `-2147483648` keeps its type.
          mk(
            Neg(a),
            a.ty,
            a.nullable || (may_overflow(a.ty) && !(a.kind is Lit(_))),
          )
        Plus => a
        BitNot => mk(BitNot(a), a.ty, a.nullable)
      }
    }
    Binary(op, l, r) => {
      let a = bind_expr(env, l)
      let b = bind_expr(env, r)
      match op {
        Add | Sub | Mul | Div | Mod => {
          let aop : @types.ArithOp = match op {
            Add => Add
            Sub => Sub
            Mul => Mul
            Div => Div
            _ => Mod
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
      bit_expr(IsNull(bind_expr(env, inner), negated~), false)
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
      let tys = branches.map(b => b.1.ty)
      if els is Some(x) {
        tys.push(x.ty)
      }
      let t = unify_types(tys)
      let nullable = els is None ||
        branches.iter().any(b => b.1.nullable) ||
        (els is Some(x) && x.nullable)
      fold_case(branches, els, t, nullable)
    }
    Cast(inner, tn, try_~) => {
      let a = bind_expr(env, inner)
      let t = resolve_type(tn, Conversion, env.collation)
      conversion(a, t, try_, None)
    }
    Convert(tn, inner, style~, try_~) => {
      let a = bind_expr(env, inner)
      let t = resolve_type(tn, Conversion, env.collation)
      let st = match style {
        None => None
        Some({ kind: IntLit(s), .. }) => Some(parse_style(s))
        Some(_) =>
          raise @types.not_supported("CONVERT with a non-constant style")
      }
      conversion(a, t, try_, st)
    }
    Collate(inner, name) => {
      let a = bind_expr(env, inner)
      let c = match @types.Collation::parse(name.name) {
        Some(c) => c
        None => raise err(448, "Invalid collation '\{name.name}'.")
      }
      let ty : @types.SqlType = match a.ty {
        Char(n, _) => Char(n, c)
        VarChar(n, _) => VarChar(n, c)
        NChar(n, _) => NChar(n, c)
        NVarChar(n, _) => NVarChar(n, c)
        other =>
          raise err(
            447,
            "Expression type \{other.base_name()} is invalid for COLLATE clause.",
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
      let (a, plan, coll) = compare_with_subquery(env, x, q)
      bit_expr(InQuery(a, plan, negated~, collation=coll), true)
    }
    Quantified(op, quant, x, q) => {
      let (a, plan, coll) = compare_with_subquery(env, x, q)
      let (o, _) = cmp_op(op)
      bit_expr(Quantified(o, a, plan, all=quant is All, collation=coll), true)
    }
    Parse(_, _, ..) => raise @types.not_supported("PARSE / TRY_PARSE")
    AtTimeZone(_, _) => raise @types.not_supported("AT TIME ZONE")
    NextValueFor(_) => raise @types.not_supported("sequences (NEXT VALUE FOR)")
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
  if !@types.can_convert_explicitly(a.ty, t) {
    raise @types.explicit_conversion_error(a.ty, t)
  }
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
    "@@DATEFIRST" => mk(Global(DateFirst), TinyInt, false)
    "@@TEXTSIZE" => int_(TextSize)
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
    "@@DBTS" => mk(Global(DbTs), VarBinary(Some(8)), false)
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
  let coll = match a.ty.collation() {
    Some(c) => Some(c)
    None => t.collation()
  }
  (a, plan, coll)
}

///|
/// Exact numeric types whose arithmetic SQL Server reports as nullable.
fn may_overflow(t : @types.SqlType) -> Bool {
  t.family() is (FInteger | FDecimal | FMoney)
}
