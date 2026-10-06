///|
/// Captured graph nodes include both pruned and pending reciprocal edges.
pub(all) struct VectorNode {
  key : Int
  vector : @types.VectorData
  neighbors : Array[Int]
}

///|
/// Search an already built graph. SQL binding validates TOP_N and the metric.
/// Equal distances use key order; the oracle's tied selections vary across builds.
/// This component does not build an index or substitute an exact table scan.
pub fn vector_search(
  nodes : Array[VectorNode],
  start : Int,
  query : @types.VectorData,
  metric : VectorMetric,
  top : Int,
) -> Array[VectorCandidate] raise @types.SqlError {
  if top <= 0 || nodes.is_empty() {
    return []
  }
  let width = @cmp.maximum(5L, top.to_int64() * 3L / 2L)
  let batch_size = @cmp.minimum(
    nodes.length().to_int64(),
    @cmp.maximum(4L, width / 6L),
  ).to_int()
  let limit = @cmp.minimum(nodes.length().to_int64(), width).to_int()
  let by_key : Map[Int, VectorNode] = Map([])
  for node in nodes {
    by_key[node.key] = node
  }
  let distances : Map[Int, Double] = Map([])
  let visited : Set[Int] = Set([])
  let mut pool : Array[VectorCandidate] = []
  if by_key.get(start) is Some(node) {
    let distance = query.distance(node.vector, metric.text())
    distances[start] = distance
    pool.push({ key: start, vector: node.vector, distance, })
  }
  while !pool.is_empty() {
    let batch = pool
      .iter()
      .filter(c => !visited.contains(c.key))
      .take(batch_size)
      .collect()
    if batch.is_empty() {
      break
    }
    let present : Set[Int] = Set([])
    for candidate in pool {
      present.add(candidate.key) |> ignore
    }
    for candidate in batch {
      visited.add(candidate.key) |> ignore
      if by_key.get(candidate.key) is Some(node) {
        for key in node.neighbors {
          if present.contains(key) {
            continue
          }
          if by_key.get(key) is Some(neighbor) {
            let distance = match distances.get(key) {
              Some(value) => value
              None => {
                let value = query.distance(neighbor.vector, metric.text())
                distances[key] = value
                value
              }
            }
            pool.push({ key, vector: neighbor.vector, distance, })
            present.add(key) |> ignore
          }
        }
      }
    }
    pool.sort_by((a, b) => {
      let order = a.distance.compare(b.distance)
      if order == 0 {
        a.key.compare(b.key)
      } else {
        order
      }
    })
    pool = pool.iter().take(limit).collect()
  }
  pool.iter().take(top).collect()
}
