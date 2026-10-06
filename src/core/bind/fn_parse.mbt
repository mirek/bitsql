// PARSE / TRY_PARSE (x AS type [USING culture]). Evaluated in
// exec/fn_parse.mbt. Captures: harness/corpus/analytic/parse-*.sql.

///|
/// Binds PARSE / TRY_PARSE as `Named("PARSE")` with arguments
/// `[text, try flag, declared type name, culture?]`. The result is always a
/// nullable computed column (flags 33); decimal reports as numeric
/// (captured: TRY_PARSE(.. AS decimal(10,2)) is NumericN).
fn bind_parse(
  env : Env,
  x : @ast.Expr,
  tn : @ast.TypeName,
  culture : @ast.Expr?,
  try_ : Bool,
) -> @ir.Expr raise @types.SqlError {
  let fname = if try_ { "TRY_PARSE" } else { "PARSE" }
  let a = bind_expr(env, x)
  // captured: TRY_PARSE reports these as "parse function" too
  if is_null_lit(a) {
    raise null_arg(1, "parse")
  }
  if a.ty.family() != FString {
    raise bad_arg_type(a.ty, 1, "parse")
  }
  // captured: a user alias type is 10761 naming it as written
  // (msduck parse-try-parse#076)
  let t = resolve_type(
    tn,
    Conversion,
    env.collation,
    preview=(env.catalog.preview_features)(),
  ) catch {
    e =>
      if (env.catalog.user_type)(tn) {
        let name = match tn.schema {
          Some(sc) => sc.name + "." + tn.name
          None => tn.name
        }
        raise err(
          10761,
          "Invalid data type \{name} in function \{fname}.",
          state=2,
          severity=15,
        )
      } else {
        raise e
      }
  }
  let ty : @types.SqlType = match t {
    TinyInt
    | SmallInt
    | Int
    | BigInt
    | Numeric(_, _)
    | Money
    | SmallMoney
    | Float
    | Real
    | Date
    | Time(_)
    | DateTime2(_)
    | DateTimeOffset(_)
    | DateTime
    | SmallDateTime => t
    Decimal(p, s) => Numeric(p, s)
    other =>
      raise err(
        10761,
        "Invalid data type \{other.base_name()} in function \{fname}.",
        state=2,
        severity=15,
      )
  }
  let lit_s = (s : String) => {
    @ir.Expr::lit(
      String(s),
      VarChar(Some(@cmp.maximum(s.length(), 1)), @types.default_collation),
    )
  }
  let args = [
    a,
    @ir.Expr::lit(Int(if try_ { 1 } else { 0 }), Int),
    // the 9819 message names the target type (decimal reads 'numeric')
    lit_s(ty.base_name()),
  ]
  match culture {
    Some(c) => args.push(bind_expr(env, c))
    None => ()
  }
  named("PARSE", args, ty)
}
