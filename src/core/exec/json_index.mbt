///|
/// Path-presence candidates for positive JSON predicates. Literal arguments
/// avoid suppressing errors from row-dependent path/mode expressions. The
/// caller evaluates the complete original predicate on every candidate.
fn json_index_candidates(
  ctx : Ctx,
  scope : Int,
  id : Int,
  conjuncts : Array[@ir.Expr],
) -> Array[(Int64, Array[@types.Value])]? {
  for e in conjuncts {
    guard e.kind is Cmp(Eq, a, b, _) else { continue }
    let call = if b.kind is Lit(Int(1)) {
      a
    } else if a.kind is Lit(Int(1)) {
      b
    } else {
      continue
    }
    guard call.kind is Call(Named(name), args) else { continue }
    let path_index = match name {
      "JSON_CONTAINS" => {
        guard args.length() == 4 &&
          args[1].kind is Lit(_) &&
          args[3].kind is (Lit(Int(0)) | Lit(Int(1)) | Lit(Null)) else {
          continue
        }
        2
      }
      "JSON_PATH_EXISTS" => 1
      _ => continue
    }
    guard args[0].ty is Json &&
      args[0].kind is Col(column) &&
      args[path_index].kind is Lit(String(path)) else {
      continue
    }
    if (ctx.seek_json)(scope, id, column, path) is Some(rows) {
      return Some(rows)
    }
  }
  None
}
