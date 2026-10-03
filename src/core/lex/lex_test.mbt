///|
fn toks(src : String) -> String {
  try @lex.lex(src) catch {
    e => e.render()
  } noraise {
    ts =>
      ts
      .map(t => {
        let k = match t.kind {
          Word => "w"
          QuotedIdent => "q"
          Str => "s"
          NStr => "n"
          IntNum => "i"
          DecimalNum => "d"
          FloatNum => "f"
          Money => "m"
          BinaryLit => "x"
          Variable => "v"
          GlobalVariable => "g"
          Punct => "p"
          Eof => "eof"
        }
        "\{k}:\{t.text}@\{t.span.line}:\{t.span.col}"
      })
      .join(" ")
  }
}

///|
test "identifiers and strings" {
  inspect(
    toks("[a]]b] \"c\"\"d\" 'e''f' N'g' n'h' ''"),
    content=(
      #|q:a]b@1:1 q:c"d@1:8 s:e'f@1:15 n:g@1:22 n:h@1:27 s:@1:32 eof:@1:34
    ),
  )
  inspect(
    toks("#t ##g $action @x @@ROWCOUNT @a#b x$y"),
    content=(
      #|w:#t@1:1 w:##g@1:4 w:$action@1:8 v:@x@1:16 g:@@ROWCOUNT@1:19 v:@a#b@1:30 w:x$y@1:35 eof:@1:38
    ),
  )
  inspect(
    toks("[multi\nline] 'multi\nline' x"),
    content=(
      #|q:multi
      #|line@1:1 s:multi
      #|line@2:7 w:x@3:7 eof:@3:8
    ),
  )
}

///|
test "numbers" {
  inspect(
    toks("1 1.5 .5 1. 1e3 1E+3 2.5e-2 1e 0x 0xAB $1.5 $.5"),
    content=(
      #|i:1@1:1 d:1.5@1:3 d:.5@1:7 d:1.@1:10 f:1e3@1:13 f:1E+3@1:17 f:2.5e-2@1:22 i:1@1:29 w:e@1:30 x:0x@1:32 x:0xAB@1:35 m:$1.5@1:40 m:$.5@1:45 eof:@1:48
    ),
  )
}

///|
test "operators longest first" {
  inspect(
    toks("a>=b<=c<>d!=e!<f!>g+=h-=i*=j/=k%=l&=m|=n^=o::p.q;(r,s)~t:u"),
    content=(
      #|w:a@1:1 p:>=@1:2 w:b@1:4 p:<=@1:5 w:c@1:7 p:<>@1:8 w:d@1:10 p:!=@1:11 w:e@1:13 p:!<@1:14 w:f@1:16 p:!>@1:17 w:g@1:19 p:+=@1:20 w:h@1:22 p:-=@1:23 w:i@1:25 p:*=@1:26 w:j@1:28 p:/=@1:29 w:k@1:31 p:%=@1:32 w:l@1:34 p:&=@1:35 w:m@1:37 p:|=@1:38 w:n@1:40 p:^=@1:41 w:o@1:43 p:::@1:44 w:p@1:46 p:.@1:47 w:q@1:48 p:;@1:49 p:(@1:50 w:r@1:51 p:,@1:52 w:s@1:53 p:)@1:54 p:~@1:55 w:t@1:56 p::@1:57 w:u@1:58 eof:@1:59
    ),
  )
}

///|
test "comments and positions" {
  inspect(
    toks("-- c\n/* a /* nested */ still */ x --tail\n  y"),
    content=(
      #|w:x@2:28 w:y@3:3 eof:@3:4
    ),
  )
  inspect(
    toks("a\r\nb"),
    content=(
      #|w:a@1:1 w:b@2:1 eof:@2:2
    ),
  )
  inspect(
    toks(""),
    content=(
      #|eof:@1:1
    ),
  )
}

///|
test "lexical errors" {
  inspect(
    toks("'abc"),
    content=(
      #|Msg 105, Level 15, State 1, Line 1: Unclosed quotation mark after the character string 'abc'.
    ),
  )
  inspect(
    toks("x /* /* */"),
    content=(
      #|Msg 113, Level 15, State 1, Line 1: Missing end comment mark '*/'.
    ),
  )
  inspect(
    toks("[abc"),
    content=(
      #|Msg 105, Level 15, State 1, Line 1: Unclosed quotation mark after the character string 'abc'.
    ),
  )
  inspect(
    toks("\"abc"),
    content=(
      #|Msg 105, Level 15, State 1, Line 1: Unclosed quotation mark after the character string 'abc'.
    ),
  )
  inspect(
    toks("a ? b"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '?'.
    ),
  )
  inspect(
    toks("a\n `b`"),
    content=(
      #|Msg 102, Level 15, State 1, Line 2: Incorrect syntax near '`'.
    ),
  )
}

///|
test "eq_upper" {
  assert_true(@lex.eq_upper("select", "SELECT"))
  assert_true(@lex.eq_upper("SeLeCt", "SELECT"))
  assert_false(@lex.eq_upper("selec", "SELECT"))
  assert_false(@lex.eq_upper("selecx", "SELECT"))
}
