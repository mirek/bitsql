///|
/// Select the closest sample row to the oracle's running average. The caller
/// supplies the repeatable sample in source scan order.
pub fn vector_seed(
  sample : Array[(Int, @types.VectorData)],
  metric : VectorMetric,
) -> Int? raise @types.SqlError {
  if sample.is_empty() {
    return None
  }
  // Float16 builds select the first sample row rather than averaging it.
  if sample[0].1.base() == @types.Float16 {
    return Some(sample[0].0)
  }
  let mean = match @types.vector_running_average(sample.map(pair => pair.1)) {
    Some(vector) => vector
    None => return None
  }
  let mut selected : (Int, Double)? = None
  for (key, vector) in sample {
    let distance = mean.distance(vector, metric.text())
    match selected {
      Some((_, previous)) if previous <= distance => ()
      _ => selected = Some((key, distance))
    }
  }
  selected.map(pair => pair.0)
}
