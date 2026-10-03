///|
/// Collation coercibility (SQL Server "collation precedence").
priv enum Coercibility {
  Explicit(@types.Collation)
  Implicit(@types.Collation)
  Default
  /// Two different implicit collations met: usable for results, not for
  /// comparisons.
  NoCollation(@types.Collation, @types.Collation)
}

///|
fn is_string(t : @types.SqlType) -> Bool {
  t.family() == FString
}

///|
fn coercibility(e : @ir.Expr) -> Coercibility {
  if !is_string(e.ty) {
    return Default
  }
  match e.kind {
    Collate(_) =>
      match e.ty.collation() {
        Some(c) => Explicit(c)
        None => Default
      }
    Col(_) | OuterCol(_, _) =>
      match e.ty.collation() {
        Some(c) => Implicit(c)
        None => Default
      }
    // a string-to-string conversion keeps the input's collation label
    Cast(a, ..) => if is_string(a.ty) { coercibility(a) } else { Default }
    Case(branches, els) => {
      let mut c = Default
      for b in branches {
        c = combine(c, coercibility(b.1)) catch { _ => c }
      }
      if els is Some(x) {
        c = combine(c, coercibility(x)) catch { _ => c }
      }
      c
    }
    Concat(a, b) | Arith(_, a, b) =>
      combine(coercibility(a), coercibility(b)) catch {
        _ => Default
      }
    Call(_, args) => {
      let mut c = Default
      for a in args {
        if is_string(a.ty) {
          c = combine(c, coercibility(a)) catch { _ => c }
        }
      }
      c
    }
    _ => Default
  }
}

///|
priv suberror ExplicitConflict {
  ExplicitConflict(@types.Collation, @types.Collation)
}

///|
fn combine(
  a : Coercibility,
  b : Coercibility,
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
    (NoCollation(_, _), _) => a
    (_, NoCollation(_, _)) => b
    (Implicit(x), Implicit(y)) => if x == y { a } else { NoCollation(x, y) }
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
/// The collation a string operation uses, or SQL Server's 468 when the
/// operands' collations cannot be resolved (two different explicit
/// collations, or a no-collation result).
fn resolve_collation(
  env : Env,
  op : String,
  operands : Array[@ir.Expr],
) -> @types.Collation? raise @types.SqlError {
  if !operands.iter().any(o => is_string(o.ty)) {
    return None
  }
  let mut c = Default
  for o in operands {
    if is_string(o.ty) {
      c = combine(c, coercibility(o)) catch {
        // SQL Server names the later operand first (captured: msduck
        // collation-functions "between CS_AS and BIN2" for BIN2 = CS_AS)
        ExplicitConflict(x, y) => raise conflict_error(y, x, op)
      }
    }
  }
  match c {
    Explicit(x) | Implicit(x) => Some(x)
    Default => Some(env.collation)
    NoCollation(x, y) => raise conflict_error(y, x, op)
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
