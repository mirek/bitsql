///|
/// True for expressions whose value does not depend on rows, variables,
/// session state or nondeterministic functions.
fn is_constant(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(_) => true
    // NOT LIKE does not fold (captured: CASE WHEN 'abc' NOT LIKE 'z%' THEN 1
    // … and CASE WHEN 'ac' LIKE 'a_c' THEN 1 WHEN NOT ('ac' LIKE 'a_c') THEN 0
    // ELSE NULL END are nullable; msduck like-patterns)
    Not({ kind: Like(_, _, ..), .. }) => false
    // string <-> date/time conversions depend on SET DATEFORMAT and SET
    // LANGUAGE, which the binder does not see: evaluated at run time
    Cast(a, ..) if session_dependent_cast(a.ty, e.ty) => false
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
    // deterministic string built-ins over constants fold too (captured:
    // msduck bin2-constant-edges, CASE WHEN LEFT(N'..',0) COLLATE .. = N''
    // THEN 1 .. is Int NOT NULL)
    Call(Named(name), args) =>
      foldable_fns.contains(name) && args.iter().all(is_constant)
    Call(IsNull | NullIf | Iif, args) => args.iter().all(is_constant)
    // captured: CASE WHEN 'alpha' LIKE 'a%' THEN 1 … is int NOT NULL
    // (msduck like-patterns)
    Like(a, p, escape~, negated=false, ..) =>
      is_constant(a) &&
      is_constant(p) &&
      (match escape {
        Some(x) => is_constant(x)
        None => true
      })
    _ => false
  }
}

///|
/// A conversion whose result depends on the session's DATEFORMAT or
/// LANGUAGE: character data to or from a date/time type.
fn session_dependent_cast(from : @types.SqlType, to : @types.SqlType) -> Bool {
  let temporal = (t : @types.SqlType) => {
    t.family() is (FDate | FTime | FDateTime)
  }
  (from.family() == FString && temporal(to)) ||
  (temporal(from) && to.family() == FString)
}

///|
/// Deterministic built-ins (bind/fn_string.mbt names) that SQL Server
/// evaluates at compile time when their arguments are constant.
let foldable_fns : Set[String] = Set([
  "CONCAT_OPERATOR", "LEN", "DATALENGTH", "UPPER", "LOWER", "REVERSE", "LTRIM", "RTRIM",
  "TRIM", "LEFT", "RIGHT", "SUBSTRING", "REPLACE", "REPLICATE", "SPACE", "CHARINDEX",
  "CONCAT", "CONCAT_WS", "NCHAR", "CHAR", "ASCII", "UNICODE", "STUFF",
])

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
    scan_row: (_, _, _) => (),
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: @exec.no_user_fn,
    user_table: @exec.no_user_table,
    seek: @exec.no_seek,
    seek_json: @exec.no_json_seek,
    vector_search: @exec.no_vector_search,
    stamp: @exec.no_stamp,
  }
  Some(@exec.eval(ctx, e)) catch {
    _ => None
  }
}

///|
/// Constant folding of arithmetic: a successful fold becomes a literal that
/// keeps the expression's nullability (captured probe: `1+1` is IntN 33,
/// `N'a'+N'b'` NVarChar 32, `'a'+NULL` 33); a failing one (1/0, overflow)
/// stays a run-time expression and is nullable (captured: msduck
/// integer-overflow, error-continuation IntN 33). String results stay
/// unfolded so COLLATE labels inside them keep their coercibility.
fn fold_arith(e : @ir.Expr) -> @ir.Expr {
  if !is_constant(e) {
    return e
  }
  match try_fold(e) {
    Some(_) if e.ty.family() == FString => e
    // a NULL int result stays an expression: a `Lit(Null)` int reads as
    // the untyped NULL constant (captured: NULL * 2 is int, 206 into
    // datetimeoffset; query/derived-untyped-null)
    Some(Null) if e.ty is Int => { ..e, nullable: true, }
    Some(v) => { kind: Lit(v), ty: e.ty, nullable: e.nullable || v is Null, }
    None => { ..e, nullable: true, }
  }
}

///|
/// Same type up to string/binary length and fixed/varying (both bounded).
/// Captured probes: IIF(1=1, CAST('a' AS char(2)), 'abc') is char(2),
/// IIF(1=1, CHAR(65), 'abc') char(1), but 'a' against N'longer' converts
/// (msduck conditional-literal-folding #009).
fn same_family(a : @types.SqlType, b : @types.SqlType) -> Bool {
  match (a, b) {
    (VarChar(Some(_), _) | Char(_, _), VarChar(Some(_), _) | Char(_, _))
    | (NVarChar(Some(_), _) | NChar(_, _), NVarChar(Some(_), _) | NChar(_, _))
    | (VarBinary(Some(_)) | Binary(_), VarBinary(Some(_)) | Binary(_)) => true
    _ => a == b
  }
}

///|
/// A conversion that can cut the value (bounded source longer than the
/// bounded target): SQL Server then reports the folded branch nullable
/// (captured probes: CASE WHEN 1=1 THEN <4001-char literal> ELSE N'x' END
/// is nvarchar(4000) flags 33, a 4000-char literal flags 32).
fn truncates(from : @types.SqlType, to : @types.SqlType) -> Bool {
  match (string_len_units(from), string_len_units(to)) {
    (Some(x), Some(y)) => x > y
    _ => false
  }
}

///|
fn string_len_units(t : @types.SqlType) -> Int? {
  match t {
    Char(n, _) | NChar(n, _) | Binary(n) => Some(n)
    VarChar(n, _) | NVarChar(n, _) | VarBinary(n) => n
    _ => None
  }
}

///|
fn is_untyped_null(e : @ir.Expr) -> Bool {
  e.kind is Lit(Null) && e.ty is Int
}

///|
/// A NULL literal of type `ty`.
fn typed_null(ty : @types.SqlType) -> @ir.Expr {
  { kind: Lit(Null), ty, nullable: true, }
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
      {
        ..coerce(x, ty),
        nullable: any_nullable || x.nullable || truncates(x.ty, ty),
      }
    }
  }
  // constant conditions fold for max types too: COALESCE(NULL, m) over an
  // nvarchar(max) column is the column (flags 9; captured: msduck
  // openjson-isnull, constraints probes)
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
  let rest = branches[i:].to_owned().map(b => (b.0, coerce(b.1, ty)))
  { kind: Case(rest, els.map(x => coerce(x, ty))), ty, nullable, }
}

///|
/// JSON_VALUE / JSON_QUERY over literal arguments are evaluated while
/// compiling: an error is a compile error (no column metadata, the batch
/// ends; captured: traps/json-lax-strict, msduck error-continuation#005).
fn constant_json_check(e : @ir.Expr) -> @ir.Expr raise @types.SqlError {
  guard e.kind is Call(_, args) && args.iter().all(a => a.kind is Lit(_)) else {
    return e
  }
  // a NULL path is 8116 at run time, after the column metadata (captured:
  // msduck json-extraction-boundaries#052)
  if args.iter().any(a => a.kind is Lit(Null)) {
    return e
  }
  let ctx : @exec.Ctx = {
    rt: fold_runtime,
    vars: [],
    row: [],
    outer: [],
    scan_row: (_, _, _) => (),
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: @exec.no_user_fn,
    user_table: @exec.no_user_table,
    seek: @exec.no_seek,
    seek_json: @exec.no_json_seek,
    vector_search: @exec.no_vector_search,
    stamp: @exec.no_stamp,
  }
  ignore(@exec.eval(ctx, e))
  e
}

///|
/// The value of a bound expression that depends on nothing at run time
/// (literals, casts and arithmetic over them), None otherwise or when its
/// evaluation fails.
pub fn constant_value(e : @ir.Expr) -> @types.Value? {
  try_fold(e)
}
