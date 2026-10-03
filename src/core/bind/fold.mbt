///|
/// True for expressions whose value does not depend on rows, variables,
/// session state or nondeterministic functions.
fn is_constant(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(_) => true
    Cast(a, ..) | Collate(a) | Neg(a) | BitNot(a) | Not(a) | IsNull(a, ..) =>
      is_constant(a)
    Arith(_, a, b)
    | BitOp(_, a, b)
    | Concat(a, b)
    | Cmp(_, a, b, _)
    | And(a, b)
    | Or(a, b) => is_constant(a) && is_constant(b)
    Case(branches, els) =>
      branches.iter().all(x => is_constant(x.0) && is_constant(x.1)) &&
      (match els {
        Some(x) => is_constant(x)
        None => true
      })
    _ => false
  }
}

///|
let fold_runtime : @exec.Runtime = @exec.Runtime::new(
  database="",
  spid=0,
  now=0L,
  seed=0L,
)

///|
/// Evaluates a constant expression at bind time; None if it raises (SQL
/// Server then leaves it to run time, where the error surfaces).
fn try_fold(e : @ir.Expr) -> @types.Value? {
  if !is_constant(e) {
    return None
  }
  let ctx : @exec.Ctx = {
    rt: fold_runtime,
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: @exec.no_user_fn,
    user_table: @exec.no_user_table,
  }
  Some(@exec.eval(ctx, e)) catch {
    _ => None
  }
}

///|
/// Constant folding of arithmetic: a successful fold becomes a non-null
/// literal; a failing one (1/0, overflow) stays a run-time expression and is
/// nullable (captured: msduck integer-overflow, error-continuation IntN 33).
/// The non-null result of a successful fold is unverified.
fn fold_arith(e : @ir.Expr) -> @ir.Expr {
  if !is_constant(e) {
    return e
  }
  match try_fold(e) {
    Some(v) => { kind: Lit(v), ty: e.ty, nullable: v is Null, }
    None => { ..e, nullable: true, }
  }
}

///|
/// Same type up to string/binary length (both bounded).
fn same_family(a : @types.SqlType, b : @types.SqlType) -> Bool {
  match (a, b) {
    (VarChar(Some(_), _), VarChar(Some(_), _))
    | (NVarChar(Some(_), _), NVarChar(Some(_), _))
    | (Char(_, _), Char(_, _))
    | (NChar(_, _), NChar(_, _))
    | (VarBinary(Some(_)), VarBinary(Some(_)))
    | (Binary(_), Binary(_)) => true
    _ => a == b
  }
}

///|
fn is_untyped_null(e : @ir.Expr) -> Bool {
  e.kind is Lit(Null) && e.ty is Int
}

///|
fn is_lob(t : @types.SqlType) -> Bool {
  t is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None))
}

///|
/// Constant CASE folding (captured: msduck case-constant-properties,
/// conditional-literal-folding). Leading constant-FALSE branches are
/// dropped; a constant-TRUE branch replaces the CASE:
/// - if its type equals the CASE type up to length, it is returned as is
///   (own length, nullability and column origin);
/// - otherwise it is converted to the CASE type and the result is nullable
///   when any branch is (an untyped NULL literal does not count).
/// LOB (max) results are never folded.
fn fold_case(
  branches : Array[(@ir.Expr, @ir.Expr)],
  els : @ir.Expr?,
  ty : @types.SqlType,
  nullable : Bool,
) -> @ir.Expr raise @types.SqlError {
  let all = branches.map(b => b.1)
  if els is Some(x) {
    all.push(x)
  }
  let any_nullable = all.iter().any(x => x.nullable && !is_untyped_null(x))
  let pick = (x : @ir.Expr) => {
    if same_family(x.ty, ty) {
      x
    } else {
      { ..coerce(x, ty), nullable: any_nullable || x.nullable, }
    }
  }
  if is_lob(ty) {
    return {
      kind: Case(
        branches.map(b => (b.0, coerce(b.1, ty))),
        els.map(x => coerce(x, ty)),
      ),
      ty,
      nullable,
    }
  }
  let mut i = 0
  while i < branches.length() {
    let cond = branches[i].0
    if !is_constant(cond) {
      break
    }
    match try_fold(cond) {
      Some(Bit(true)) => return pick(branches[i].1)
      Some(_) => i += 1
      None => break
    }
  }
  if i == branches.length() {
    return match els {
      Some(x) => pick(x)
      None => { kind: Lit(Null), ty, nullable: true, }
    }
  }
  let rest = branches[i:].to_owned().map(b => (b.0, coerce(b.1, ty)))
  { kind: Case(rest, els.map(x => coerce(x, ty))), ty, nullable, }
}
