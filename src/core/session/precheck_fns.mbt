// Batch-level compile checks of built-in function arguments (called from
// precheck.mbt).

///|
/// 8748 when STRING_SPLIT's enable_ordinal mentions a variable or
/// parameter (captured: msduck string-split #036, #048).
fn string_split_ordinal_error(t : @ast.TableRef) -> (@types.SqlError, Int)? {
  match t.kind {
    TableFunc(name, args, ..) if name.base().to_upper() == "STRING_SPLIT" &&
      args.length() == 3 => {
      let mut has_var = false
      walk_expr(args[2], x => if x.kind is Var(_) { has_var = true })
      if has_var {
        Some(
          (
            @types.sql_error(
              8748, "The enable_ordinal argument for string_split only supports constant values (not variables or columns).",
            ),
            t.span.line,
          ),
        )
      } else {
        None
      }
    }
    Join(_, a, b, ..) =>
      match string_split_ordinal_error(a) {
        Some(e) => Some(e)
        None => string_split_ordinal_error(b)
      }
    _ => None
  }
}
