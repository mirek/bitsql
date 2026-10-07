///|
fn vector_build_candidates(
  source : @types.VectorData,
  nodes : Array[VectorNode],
  metric : VectorMetric,
) -> Array[VectorCandidate] raise @types.SqlError {
  let candidates : Array[VectorCandidate] = []
  for node in nodes {
    candidates.push({
      key: node.key,
      vector: node.vector,
      distance: source.distance(node.vector, metric.text()),
    })
  }
  candidates.sort_by(vector_candidate_order)
  candidates
}

///|
fn vector_build_batch_size(processed : Int, alignment : Int) -> Int {
  let mut size = 256
  for
    (threshold, next) in [
      (3840, 960),
      (7680, 1920),
      (15360, 3840),
      (30720, 7680),
      (61440, 11520),
      (122880, 15360),
      (245760, 23040),
      (491520, 30720),
    ] {
    if processed > threshold {
      size = next
    }
  }
  if size > alignment {
    size / alignment * alignment
  } else {
    size
  }
}

///|
/// Assemble a graph from an oracle-established start key and page/DOP alignment.
/// Seed selection and SQL option validation belong to the index construction
/// caller. The seed and subsequent batches use separate reciprocal-edge phases.
pub fn vector_build(
  input : Array[(Int, @types.VectorData)],
  start : Int,
  metric : VectorMetric,
  alignment? : Int = 480,
) -> VectorGraph raise @types.SqlError {
  if alignment <= 0 {
    raise @types.not_supported("invalid vector graph batch alignment")
  }
  let ordered = input.copy()
  ordered.sort_by((a, b) => a.0.compare(b.0))
  let all_nodes : Array[VectorNode] = ordered.map(pair => {
    key: pair.0,
    vector: pair.1,
    neighbors: [],
  })
  let mut graph = VectorGraph::new(all_nodes, start)
  let others = all_nodes.filter(n => n.key != start)
  let initial = vector_build_batch_size(0, alignment)
  let seed = others.iter().take(initial).collect()
  if graph.nodes.get(start) is Some(node) {
    seed.push(node)
  }
  for node in seed {
    let candidates = vector_build_candidates(
      node.vector,
      seed.filter(n => n.key != node.key),
      metric,
    )
    let updated = { ..node, neighbors: vector_prune(candidates, metric), }
    graph = { ..graph, nodes: graph.nodes.add(node.key, updated), }
  }
  let pending : Map[Int, Array[Int]] = Map([])
  let mut position = @cmp.minimum(initial, others.length())
  let mut processed = seed.length()
  while position < others.length() {
    let size = vector_build_batch_size(processed, alignment)
    let end = position + @cmp.minimum(size, others.length() - position)
    let before_batch = graph
    let reciprocal : Map[Int, Array[Int]] = Map([])
    for i in position..<end {
      let node = others[i]
      let candidates = before_batch.walk(node.vector, metric, 48, 8, true)
      let neighbors = vector_prune(candidates, metric)
      graph = {
        ..graph,
        nodes: graph.nodes.add(node.key, { ..node, neighbors, }),
      }
      for key in neighbors {
        match reciprocal.get(key) {
          Some(keys) => keys.push(node.key)
          None => reciprocal[key] = [node.key]
        }
      }
    }
    for key, new_keys in reciprocal {
      if graph.nodes.get(key) is Some(node) {
        let prior_pending = pending.get(key).unwrap_or([])
        let next_pending = prior_pending + new_keys
        if next_pending.length() >= 14 {
          let candidates = vector_build_candidates(
            node.vector,
            (node.neighbors + new_keys).filter_map(k => graph.nodes.get(k)),
            metric,
          )
          let neighbors = vector_prune(candidates, metric)
          graph = {
            ..graph,
            nodes: graph.nodes.add(key, { ..node, neighbors, }),
          }
          pending[key] = []
        } else {
          graph = {
            ..graph,
            nodes: graph.nodes.add(key, {
              ..node,
              neighbors: node.neighbors + new_keys,
            }),
          }
          pending[key] = next_pending
        }
      }
    }
    processed += end - position
    position = end
  }
  graph
}
