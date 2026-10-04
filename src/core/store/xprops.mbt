// Extended properties (sp_addextendedproperty, sys.extended_properties).
// Stored per (class, major_id, minor_id, name); a property whose object or
// column no longer exists is skipped by readers (the session filters), so
// DROP TABLE / ALTER TABLE DROP COLUMN need no bookkeeping here.

///|
/// One extended property. `class` 1 is an object or column (major_id the
/// object id, minor_id the column id or 0), 3 a schema (major_id the
/// schema id). `value` is a sql_variant value or Null.
pub(all) struct ExtendedProperty {
  class : Int
  major_id : Int
  minor_id : Int
  name : String
  value : @types.Value
} derive(Debug, Eq)

///|
fn xprop_key(class : Int, major : Int, minor : Int, name : String) -> String {
  // fixed-width numbers keep the map in (class, major, minor, name) order
  let pad = (n : Int) => {
    let t = (n.to_int64() + 0x80000000L).to_string()
    "0".repeat(11 - t.length()) + t
  }
  "\{class}.\{pad(major)}.\{pad(minor)}.\{name.to_lower()}"
}

///|
/// The property `name` (case-insensitive) of (class, major, minor).
pub fn Db::xprop(
  self : Db,
  class : Int,
  major : Int,
  minor : Int,
  name : String,
) -> ExtendedProperty? {
  self.props.get(xprop_key(class, major, minor, name))
}

///|
/// Adds or replaces a property.
pub fn Db::set_xprop(self : Db, p : ExtendedProperty) -> Db {
  {
    ..self,
    props: self.props.add(xprop_key(p.class, p.major_id, p.minor_id, p.name), p),
  }
}

///|
pub fn Db::drop_xprop(
  self : Db,
  class : Int,
  major : Int,
  minor : Int,
  name : String,
) -> Db {
  { ..self, props: self.props.remove(xprop_key(class, major, minor, name)), }
}

///|
/// Every stored property in (class, major_id, minor_id, name) order.
pub fn Db::xprops(self : Db) -> Array[ExtendedProperty] {
  self.props.iter().map(kv => kv.1).collect()
}
