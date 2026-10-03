// The xml data type's value: a parsed, untyped XML fragment (SQL Server's
// xml(CONTENT)), kept as a tree so methods can navigate it. Serialization
// (serialize.mbt) reproduces SQL Server's canonical text form.

///|
/// A qualified name as written (`prefix:lname`) with its namespace URI
/// resolved at parse time ("" = no namespace).
pub(all) struct QName {
  prefix : String
  lname : String
  ns : String
} derive(Eq, Debug)

///|
pub fn QName::text(self : QName) -> String {
  if self.prefix == "" {
    self.lname
  } else {
    self.prefix + ":" + self.lname
  }
}

///|
/// An attribute. Namespace declarations (`xmlns`, `xmlns:p`) are kept as
/// attributes (namespace `xmlns_ns`) so they serialize where written.
pub(all) struct Attr {
  name : QName
  value : String
} derive(Eq, Debug)

///|
pub let xmlns_ns : String = "http://www.w3.org/2000/xmlns/"

///|
pub let xml_ns : String = "http://www.w3.org/XML/1998/namespace"

///|
pub(all) enum Node {
  Element(QName, Array[Attr], Array[Node])
  Text(String)
  Comment(String)
  /// processing instruction: target, data
  Pi(String, String)
} derive(Eq, Debug)

///|
/// An xml value: the document's top-level nodes, plus the context node of a
/// `nodes()` row (`path` of child indexes from the document, `attr` the
/// attribute index on that element or -1). A plain value has an empty path.
pub(all) struct Xml {
  nodes : Array[Node]
  path : Array[Int]
  attr : Int
} derive(Eq, Debug)

///|
pub fn Xml::of_nodes(nodes : Array[Node]) -> Xml {
  { nodes, path: [], attr: -1, }
}

///|
/// Is this a `nodes()` context reference rather than a whole document?
pub fn Xml::is_ref(self : Xml) -> Bool {
  !self.path.is_empty() || self.attr >= 0
}

///|
/// Is this attribute a namespace declaration?
pub fn Attr::is_namespace_decl(self : Attr) -> Bool {
  self.name.ns == xmlns_ns
}
