///|
/// A candidate supplied in ascending source-distance order. The caller owns
/// tie ordering; pruning must preserve it. Keys are clustered INT primary keys.
pub(all) struct VectorCandidate {
  key : Int
  vector : @types.VectorData
  distance : Double
}

///|
pub(all) enum VectorMetric {
  Cosine
  Euclidean
  Dot
} derive(Eq, Debug)

///|
pub fn VectorMetric::text(self : VectorMetric) -> String {
  match self {
    Cosine => "cosine"
    Euclidean => "euclidean"
    Dot => "dot"
  }
}

///|
/// SQL Server's graph pruning resumes from a candidate position on the
/// second alpha pass. A newly selected neighbor before that position is not
/// checked again. This differs from eagerly updating every later candidate.
/// Evidence: sql2025/vector-pruning#resume-minimal and independent graph captures.
/// Returns keys in candidate order, with a maximum degree of 48.
pub fn vector_prune(
  candidates : Array[VectorCandidate],
  metric : VectorMetric,
) -> Array[Int] raise @types.SqlError {
  let factors = Array::make(candidates.length(), 0.0)
  let next = Array::make(candidates.length(), 0)
  let selected = Array::make(candidates.length(), false)
  let mut count = 0
  for alpha in [1.0, Float::from_double(1.2).to_double()] {
    for i, candidate in candidates {
      if count == 48 {
        break
      }
      if selected[i] || factors[i] > alpha {
        continue
      }
      while next[i] < i {
        let j = next[i]
        next[i] += 1
        if !selected[j] {
          continue
        }
        let between = candidate.vector.distance(
          candidates[j].vector,
          metric.text(),
        )
        let ratio = if between == 0.0 {
          3.4028234663852886e38
        } else {
          Float::from_double(candidate.distance / between).to_double()
        }
        if ratio > factors[i] {
          factors[i] = ratio
        }
        if factors[i] > alpha {
          break
        }
      }
      if factors[i] <= alpha {
        selected[i] = true
        count += 1
      }
    }
  }
  let out = []
  for i, candidate in candidates {
    if selected[i] {
      out.push(candidate.key)
    }
  }
  out
}
