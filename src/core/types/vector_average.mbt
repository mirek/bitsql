///|
/// The vector-index seed aggregate uses an incremental float32 average.
/// The caller supplies its ordered sample; this is not a SQL-visible aggregate.
pub fn vector_running_average(
  input : Array[VectorData],
) -> VectorData? raise SqlError {
  if input.is_empty() {
    return None
  }
  let first = input[0]
  if first.base_type != Float32 {
    raise not_supported("float16 vector index seed average")
  }
  let mean = first.components.copy()
  for i in 1..<input.length() {
    let next = input[i]
    if next.base_type != Float32 || next.dimensions() != mean.length() {
      raise not_supported("mixed vector index seed types")
    }
    let count = vector_f32((i + 1).to_double())
    for j, value in next.components {
      let delta = vector_f32(value - mean[j])
      mean[j] = vector_f32(mean[j] + vector_f32(delta / count))
    }
  }
  Some({ components: mean, base_type: Float32, })
}
