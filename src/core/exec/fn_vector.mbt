///|
fn call_vector(
  name : String,
  values : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value? raise @types.SqlError {
  if name == "VECTOR_DISTANCE" {
    if values.any(v => v is Null) {
      return Some(Null)
    }
    guard values[0] is String(metric) &&
      values[1] is Vector(a) &&
      values[2] is Vector(b) else {
      raise @types.not_supported("invalid vector distance arguments")
    }
    return Some(Float(a.distance(b, metric)))
  }
  if !(name is ("VECTOR_NORM" | "VECTOR_NORMALIZE" | "VECTORPROPERTY")) {
    return None
  }
  if values.any(v => v is Null) {
    return Some(Null)
  }
  guard values[0] is Vector(data) && values[1] is String(option) else {
    raise @types.not_supported("invalid vector function arguments")
  }
  Some(
    match name {
      "VECTOR_NORM" => Float(data.norm(option))
      "VECTOR_NORMALIZE" => Vector(data.normalize(option))
      _ =>
        match option.to_lower() {
          "dimensions" => Variant(SmallInt(data.dimensions()), SmallInt)
          "basetype" =>
            Variant(
              String(data.base().name()),
              NVarChar(
                Some(7),
                args[1].ty.collation().unwrap_or(@types.default_collation),
              ),
            )
          _ => Null
        }
    },
  )
}
