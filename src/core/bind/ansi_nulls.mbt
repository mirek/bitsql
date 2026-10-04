// SET ANSI_NULLS OFF (probed: tail/settings-ansi-nulls). `=` and `<>`
// (also `!=`, IN lists, simple CASE) become two-valued when one operand is
// a NULL literal (possibly parenthesized) or a bare variable/parameter:
// NULL = NULL is true, x = NULL is false for non-NULL x, <> is the
// negation. Column = column, expressions (`@v + 1`, CAST(NULL AS int)) and
// the ordering operators keep three-valued logic. IN / ALL / ANY over a
// subquery compare non-ANSI even between columns; bitsql raises an
// Emulator error for those when either side may be NULL.

///|
/// An operand that makes a comparison non-ANSI under ANSI_NULLS OFF.
fn null_comparand(e : @ast.Expr) -> Bool {
  match e.kind {
    Null | Var(_) => true
    Paren(x) => null_comparand(x)
    _ => false
  }
}

///|
/// Is the operand a NULL literal (possibly parenthesized)?
fn null_literal_operand(e : @ast.Expr) -> Bool {
  match e.kind {
    Null => true
    Paren(x) => null_literal_operand(x)
    _ => false
  }
}

///|
/// Under ANSI_NULLS OFF, the two-valued form of the bound comparison `cmp`
/// (Eq or Ne over `a` and `b`) when an operand is a NULL literal or a
/// variable; otherwise `cmp` itself.
fn non_ansi(
  env : Env,
  op : @ir.CmpOp,
  left : @ast.Expr,
  right : @ast.Expr,
  a : @ir.Expr,
  b : @ir.Expr,
  cmp : @ir.Expr,
) -> @ir.Expr {
  if env.ansi_nulls || !(op is (Eq | Ne)) {
    return cmp
  }
  if !null_comparand(left) && !null_comparand(right) {
    return cmp
  }
  let is_null = (x : @ir.Expr) => bit_expr(IsNull(x, negated=false), false)
  let not_null = (x : @ir.Expr) => bit_expr(IsNull(x, negated=true), false)
  let and_ = (x : @ir.Expr, y : @ir.Expr) => {
    bit_expr(And(x, y), x.nullable || y.nullable)
  }
  let eq_cmp = match cmp.kind {
    Cmp(_, x, y, coll) => bit_expr(Cmp(Eq, x, y, coll), cmp.nullable)
    _ => cmp
  }
  let eq = if null_literal_operand(right) {
    is_null(a)
  } else if null_literal_operand(left) {
    is_null(b)
  } else {
    bit_expr(
      Or(
        and_(is_null(a), is_null(b)),
        and_(and_(not_null(a), not_null(b)), eq_cmp),
      ),
      false,
    )
  }
  match op {
    Eq => eq
    _ => bit_expr(Not(eq), false)
  }
}

///|
/// IN / NOT IN over a list under ANSI_NULLS OFF with a NULL literal or a
/// variable among the operands: an OR of per-item comparisons (each
/// non-ANSI only where it involves such an operand), negated for NOT IN.
/// None when the list keeps its ANSI semantics.
fn non_ansi_in_list(
  env : Env,
  x : @ast.Expr,
  items : Array[@ast.Expr],
  a : @ir.Expr,
  bs : Array[@ir.Expr],
  coll : @types.Collation?,
  negated : Bool,
) -> @ir.Expr? {
  if env.ansi_nulls || (!null_comparand(x) && !items.iter().any(null_comparand)) {
    return None
  }
  let mut acc : @ir.Expr? = None
  for i, b in bs {
    let cmp = bit_expr(Cmp(Eq, a, b, coll), a.nullable || b.nullable)
    let c = non_ansi(env, Eq, x, items[i], a, b, cmp)
    acc = Some(
      match acc {
        None => c
        Some(p) => bit_expr(Or(p, c), p.nullable || c.nullable)
      },
    )
  }
  guard acc is Some(e) else { return None }
  Some(if negated { bit_expr(Not(e), e.nullable) } else { e })
}

///|
/// IN / NOT IN / `= ALL|ANY` / `<> ALL|ANY` over a subquery under
/// ANSI_NULLS OFF: every comparison is two-valued, NULL matching NULL
/// (probed: `a IN (SELECT b ...)` finds a NULL `a` when some `b` is NULL;
/// `a = ALL (SELECT NULL)` holds for a NULL `a`). Built from three-valued
/// pieces over the NULL and non-NULL rows of the subquery separately.
fn non_ansi_subquery(
  op : @ir.CmpOp,
  a : @ir.Expr,
  plan : @ir.Plan,
  coll : @types.Collation?,
  all~ : Bool,
  negated~ : Bool,
) -> @ir.Expr {
  let col = mk(Col(0), a.ty, true)
  let nulls : @ir.Plan = Filter(
    plan,
    bit_expr(IsNull(col, negated=false), false),
  )
  let values : @ir.Plan = Filter(
    plan,
    bit_expr(IsNull(col, negated=true), false),
  )
  let x_null = bit_expr(IsNull(a, negated=false), false)
  let x_set = bit_expr(IsNull(a, negated=true), false)
  let and_ = (x : @ir.Expr, y : @ir.Expr) => bit_expr(And(x, y), false)
  let or_ = (x : @ir.Expr, y : @ir.Expr) => bit_expr(Or(x, y), false)
  let not_ = (x : @ir.Expr) => bit_expr(Not(x), false)
  let exists = (p : @ir.Plan) => bit_expr(Exists(p), false)
  // some row equal to a (NULL equal to NULL)
  let any_eq = or_(
    and_(x_null, exists(nulls)),
    and_(
      x_set,
      bit_expr(InQuery(a, values, negated=false, collation=coll), false),
    ),
  )
  // every row equal to a
  let all_eq = or_(
    and_(x_null, not_(exists(values))),
    and_(
      x_set,
      and_(
        not_(exists(nulls)),
        bit_expr(Quantified(Eq, a, values, all=true, collation=coll), false),
      ),
    ),
  )
  let r = match (op, all) {
    (Eq, false) => any_eq
    (Eq, true) => all_eq
    // <> ALL: no row equal; <> ANY: not every row equal
    (_, true) => not_(any_eq)
    (_, false) => not_(all_eq)
  }
  if negated {
    not_(r)
  } else {
    r
  }
}
