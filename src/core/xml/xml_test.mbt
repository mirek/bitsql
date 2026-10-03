// Expected texts are from captures (harness/corpus/xml/type, methods).

///|
fn rt(s : String, preserve? : Bool = false) -> String {
  try @xml.parse(s, preserve~) catch {
    @xml.Sql(n, _, m) => "error \{n}: \{m}"
    @xml.Unsupported(m) => "unsupported: \{m}"
  } noraise {
    x => x.to_text()
  }
}

///|
test "parse and serialize" {
  inspect(
    rt(
      "<?xml version=\"1.0\"?><a><!-- c --><b x='1' y=\"2&quot;&apos;\">t&lt;&gt;&amp;&#65;&#x42;</b><![CDATA[<cd>]]><?pi data?></a>",
    ),
    content="<a><!-- c --><b x=\"1\" y=\"2&quot;'\">t&lt;&gt;&amp;AB</b>&lt;cd&gt;<?pi data?></a>",
  )
  inspect(rt("  <a>  x  <b> </b>  </a>  "), content="<a>  x  <b/></a>")
  inspect(
    rt("<a>  x  <b> </b>  </a>", preserve=true),
    content="<a>  x  <b>&#x20;</b> &#x20;</a>",
  )
  inspect(rt("<a>&#x0D;&#13;\r\n</a>"), content="<a>&#x0D;&#x0D;\n</a>")
  inspect(
    rt("<a b=\"&#x0D;&#x09;x\ty\n\"/>"),
    content="<a b=\"&#x0D;&#x09;x y \"/>",
  )
  inspect(
    rt("<a>"),
    content="error 9400: XML parsing: line 1, character 3, unexpected end of input",
  )
  inspect(
    rt("<a></b>"),
    content="error 9436: XML parsing: line 1, character 7, end tag does not match start tag",
  )
  inspect(
    rt("<a b=1/>"),
    content="error 9413: XML parsing: line 1, character 6, A string literal was expected",
  )
  inspect(
    rt("<a>&foo;</a>"),
    content="error 9448: XML parsing: line 1, character 8, well formed check: undeclared entity",
  )
  inspect(
    rt("<a b=\"1\" b=\"2\"/>"),
    content="error 9437: XML parsing: line 1, character 16, duplicate attribute",
  )
  inspect(
    rt("<a xmlns=\"urn:x\" xmlns:p=\"urn:p\"><p:b p:c=\"1\"/></a>"),
    content="<a xmlns=\"urn:x\" xmlns:p=\"urn:p\"><p:b p:c=\"1\"/></a>",
  )
}

///|
fn v(doc : String, path : String) -> String {
  try {
    let p = @xml.compile(path, "value")
    p.check_singleton()
    @xml.value(@xml.parse(doc), p)
  } catch {
    @xml.Sql(n, _, m) => "error \{n}: \{m}"
    @xml.Unsupported(m) => "unsupported: \{m}"
  } noraise {
    r => r.unwrap_or("NULL")
  }
}

///|
test "value" {
  let d = "<r><i n=\"1\">a</i><i n=\"2\">b</i><i n=\"3\"><j>c</j></i></r>"
  inspect(v(d, "(/r/i)[1]"), content="a")
  inspect(v(d, "(/r/i/@n)[3]"), content="3")
  inspect(v(d, "(/r/i[@n=\"2\"])[1]"), content="b")
  inspect(v(d, "(//j)[1]"), content="c")
  inspect(v(d, "(/r/i[3]/j/text())[1]"), content="c")
  inspect(v(d, "count(/r/i)"), content="3")
  inspect(v(d, "(/r/i)[9]"), content="NULL")
  inspect(v(d, "."), content="abc")
  inspect(v(d, "(/r/i[@n=2])[1]"), content="b")
  inspect(v(d, "(/r/i[@n>1])[1]"), content="b")
  inspect(v(d, "(/r/i[last()])[1]"), content="c")
  inspect(v(d, "(/r/*)[2]"), content="b")
  inspect(v(d, "(/r/i/@*)[2]"), content="2")
  inspect(v(d, "local-name((/r/*)[1])"), content="i")
  inspect(v(d, "string((/r/i)[1])"), content="a")
  inspect(v(d, "(/r/i[. = \"b\"]/@n)[1]"), content="2")
  inspect(v(d, "(r/i)[1]"), content="a")
  inspect(v(d, "(/r/i)[1]/@n"), content="1")
  inspect(v(d, "/r[1]/i[1]/@n"), content="1")
  inspect(
    v(d, "/r/i"),
    content="error 2389: XQuery [value()]: 'value()' requires a singleton (or empty sequence), found operand of type 'xdt:untypedAtomic *'",
  )
  inspect(
    v(d, "(/r/i[)[1]"),
    content="error 2209: XQuery [value()]: Syntax error near ')'",
  )
  inspect(v(d, "(/r/i/j/..)[1]/@n"), content="3")
}
