// Bounds kernel of `@tds.Reader` (specs in bounds.mbtp). Every length it
// checks comes off the wire, so the check itself must not overflow: the
// earlier `pos + n > len` wrapped for n near 2^31 (an NText length, a LOGIN7
// FeatureExt length), passed, and the next read aborted the server.

///|
/// Do `count` elements of `width` bytes fit between `pos` and `len`?
pub fn fits(
  pos : Int,
  count : Int,
  width : Int,
  len : Int,
) -> Bool where {
  proof_require: 0 <= pos && pos <= len,
  proof_require: 1 <= width,
  proof_ensure: result => fits_sound(pos, count, width, len, result),
  proof_ensure: result => fits_complete(pos, count, width, len, result),
} {
  count >= 0 && count <= (len - pos) / width
}
