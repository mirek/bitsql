///|
priv enum Node {
  Empty
  Rune(Array[(Int, Int)], Bool, Bool)
  ByteAny
  Assert(Int)
  Sequence(Array[Node])
  Choice(Array[Node])
  Repeat(Node, Int, Int?, Bool)
  Capture(Int, Node)
}

///|
priv enum Op {
  Accept
  Rune(Array[(Int, Int)], Bool, Bool, Int)
  ByteAny(Int)
  Assert(Int, Int)
  Save(Int, Int)
  Split(Int, Int)
}

///|
pub struct Program {
  priv code : Array[Op]
  priv entry : Int
  groups : Int
}

///|
pub struct Match {
  /// UTF-8 byte offsets, end-exclusive; group zero is the whole match.
  groups : Array[(Int, Int)?]
}

///|
fn emit(code : Array[Op], op : Op) -> Int raise @types.SqlError {
  if code.length() >= 100000 {
    raise @types.emulator_error(
      @types.EMU_WORK_BUDGET,
      "regular expression compilation exceeded the instruction budget",
    )
  }
  let pc = code.length()
  code.push(op)
  pc
}

///|
fn lower(
  node : Node,
  next : Int,
  code : Array[Op],
) -> Int raise @types.SqlError {
  match node {
    Empty => next
    Rune(ranges, negate, fold) => emit(code, Rune(ranges, negate, fold, next))
    ByteAny => emit(code, ByteAny(next))
    Assert(kind) => emit(code, Assert(kind, next))
    Capture(group, node) => {
      let end = emit(code, Save(group * 2 + 1, next))
      let body = lower(node, end, code)
      emit(code, Save(group * 2, body))
    }
    Sequence(nodes) => {
      let mut at = next
      for i = nodes.length() - 1; i >= 0; i = i - 1 {
        at = lower(nodes[i], at, code)
      }
      at
    }
    Choice(nodes) => {
      let mut at = lower(nodes[nodes.length() - 1], next, code)
      for i = nodes.length() - 2; i >= 0; i = i - 1 {
        let first = lower(nodes[i], next, code)
        at = emit(code, Split(first, at))
      }
      at
    }
    Repeat(node, min, max, greedy) => {
      let mut at = next
      match max {
        None => {
          let split = emit(code, Accept)
          let body = lower(node, split, code)
          code[split] = if greedy {
            Split(body, next)
          } else {
            Split(next, body)
          }
          // Keep the initial choice distinct from the loop choice. A nullable
          // repeated capture must participate once on an empty overall match,
          // but a zero-width final iteration must not erase a prior capture.
          at = if min == 0 {
            emit(
              code,
              if greedy {
                Split(body, next)
              } else {
                Split(next, body)
              },
            )
          } else {
            split
          }
        }
        Some(max) =>
          for _ in min..<max {
            let body = lower(node, at, code)
            at = emit(
              code,
              if greedy {
                Split(body, at)
              } else {
                Split(at, body)
              },
            )
          }
      }
      for _ in 0..<min {
        at = lower(node, at, code)
      }
      at
    }
  }
}

///|
fn program(node : Node, groups : Int) -> Program raise @types.SqlError {
  let code : Array[Op] = [Accept]
  let entry = lower(Capture(0, node), 0, code)
  { code, entry, groups: groups + 1, }
}
