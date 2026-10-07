///|
/// Captured graph nodes include both pruned and pending reciprocal edges.
pub(all) struct VectorNode {
  key : Int
  vector : @types.VectorData
  neighbors : Array[Int]
}

///|
/// Immutable graph lookup shared by searches and database snapshots.
pub struct VectorGraph {
  priv nodes : PMap[Int, VectorNode]
  priv start : Int
}

///|
pub fn VectorGraph::new(nodes : Array[VectorNode], start : Int) -> VectorGraph {
  let mut lookup = PMap::empty((a : Int, b : Int) => a.compare(b))
  for node in nodes {
    lookup = lookup.add(node.key, { ..node, neighbors: node.neighbors.copy(), })
  }
  { nodes: lookup, start, }
}

///|
pub fn VectorGraph::nodes(self : VectorGraph) -> Array[VectorNode] {
  self.nodes
  .iter()
  .map(pair => {
    let node = pair.1
    { ..node, neighbors: node.neighbors.copy(), }
  })
  .collect()
}

///|
fn vector_candidate_order(a : VectorCandidate, b : VectorCandidate) -> Int {
  let order = a.distance.compare(b.distance)
  if order == 0 {
    a.key.compare(b.key)
  } else {
    order
  }
}

///|
/// FOR INDEX CREATE returns both the final frontier and expanded nodes.
/// Query-time search returns only the final frontier.
fn VectorGraph::walk(
  self : VectorGraph,
  query : @types.VectorData,
  metric : VectorMetric,
  width : Int,
  expansion : Int,
  for_build : Bool,
) -> Array[VectorCandidate] raise @types.SqlError {
  let batch_size = @cmp.minimum(self.nodes.size(), expansion)
  let limit = @cmp.minimum(self.nodes.size(), width)
  let distances : Map[Int, Double] = Map([])
  let visited : Map[Int, VectorCandidate] = Map([])
  let mut pool : Array[VectorCandidate] = []
  if self.nodes.get(self.start) is Some(node) {
    let distance = query.distance(node.vector, metric.text())
    distances[self.start] = distance
    pool.push({ key: self.start, vector: node.vector, distance, })
  }
  while !pool.is_empty() {
    let batch = pool
      .iter()
      .filter(c => visited.get(c.key) is None)
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
      visited[candidate.key] = candidate
      if self.nodes.get(candidate.key) is Some(node) {
        for key in node.neighbors {
          if present.contains(key) {
            continue
          }
          if self.nodes.get(key) is Some(neighbor) {
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
    pool.sort_by(vector_candidate_order)
    pool = pool.iter().take(limit).collect()
  }
  if for_build {
    let present : Set[Int] = Set([])
    for candidate in pool {
      present.add(candidate.key) |> ignore
    }
    for key, candidate in visited {
      if !present.contains(key) {
        pool.push(candidate)
      }
    }
    pool.sort_by(vector_candidate_order)
  }
  pool
}

///|
/// SQL binding validates TOP_N and the metric before invoking this component.
pub fn VectorGraph::search(
  self : VectorGraph,
  query : @types.VectorData,
  metric : VectorMetric,
  top : Int,
) -> Array[VectorCandidate] raise @types.SqlError {
  if top <= 0 || self.nodes.is_empty() {
    return []
  }
  let width = @cmp.maximum(5L, top.to_int64() * 3L / 2L)
  let expansion = @cmp.minimum(
    self.nodes.size().to_int64(),
    @cmp.maximum(4L, width / 6L),
  ).to_int()
  let limit = @cmp.minimum(self.nodes.size().to_int64(), width).to_int()
  self.walk(query, metric, limit, expansion, false).iter().take(top).collect()
}

///|
/// Convenience entry point for captured graphs. Integrated indexes retain a
/// VectorGraph so queries share its immutable lookup instead of rebuilding it.
pub fn vector_search(
  nodes : Array[VectorNode],
  start : Int,
  query : @types.VectorData,
  metric : VectorMetric,
  top : Int,
) -> Array[VectorCandidate] raise @types.SqlError {
  VectorGraph::new(nodes, start).search(query, metric, top)
}
