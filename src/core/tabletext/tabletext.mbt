///|
/// Generated tables as text, decoded on first use. An array literal compiles
/// to one constructor call per element in the module's start function: the
/// tables made it 932 KB of wasm, which V8 tiered up with a 2 GB, 12 s
/// optimizing compile (decisions.md 2026-10-26). Text is data.
///
/// A bad field is a generator bug.
pub fn int(field : StringView) -> Int {
  @string.parse_int(field) catch {
    _ => abort("bad generated table field: \{field}")
  }
}

///|
pub fn int64(field : StringView) -> Int64 {
  @string.parse_int64(field) catch {
    _ => abort("bad generated table field: \{field}")
  }
}

///|
/// Lines of comma-separated integers.
pub fn int_rows(text : String) -> Array[Array[Int]] {
  text.split("\n").map(line => line.split(",").map(int).collect()).collect()
}
