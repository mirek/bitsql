///|
/// True for expressions whose value does not depend on rows, variables,
/// session state or nondeterministic functions.
fn is_constant(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(_) => true
    Cast(a, ..) | Neg(a) | BitNot(a) | Not(a) | IsNull(a, ..) => is_constant(a)
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
/// Constant CASE folding (captured: msduck case-constant-properties,
/// conditional-literal-folding): leading constant-FALSE branches are dropped
/// and a constant-TRUE branch replaces the whole CASE, keeping that branch's
/// nullability and column origin.
fn fold_case(
  branches : Array[(@ir.Expr, @ir.Expr)],
  els : @ir.Expr?,
  ty : @types.SqlType,
  nullable : Bool,
) -> @ir.Expr raise @types.SqlError {
  let mut i = 0
  while i < branches.length() {
    let cond = branches[i].0
    if !is_constant(cond) {
      break
    }
    match try_fold(cond) {
      Some(Bit(true)) => return coerce(branches[i].1, ty)
      Some(_) => i += 1
      None => break
    }
  }
  if i == branches.length() {
    return match els {
      Some(x) => coerce(x, ty)
      None => { kind: Lit(Null), ty, nullable: true, }
    }
  }
  let rest = branches[i:].to_owned()
  { kind: Case(rest, els), ty, nullable, }
}
