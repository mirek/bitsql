-- JSON path lexer errors (13607 states: 14 known token misplaced or end,
-- 22 unknown word/symbol outside brackets, 21 inside brackets, 15 number
-- followed by a word character, 16 index overflow, 17 bad escape, 20
-- unterminated quoted key) and the whitespace SQL Server accepts.
-- @step batch
SELECT JSON_VALUE(N'{"a":{"b":1}}', N'$.a .b') a, JSON_VALUE(N'{"a":1}', N'  $.a') b, JSON_VALUE(N'{"a":1}', N'strict$.a') c, JSON_VALUE(N'{"a":1}', N'lax  $.a') d, JSON_VALUE(N'{"a":1}', N'$ . "a" ') e, JSON_VALUE(N'{"a":[5]}', N'$.a [0]') f, JSON_VALUE(N'{"a":1}', NCHAR(9) + N'$.a' + NCHAR(9)) g, JSON_VALUE(N'[1,2]', N'$[ 1 ]') h, JSON_VALUE(N'{"a_b":1}', N'$.a_b') i, JSON_VALUE(N'{"a1":1}', N'$.a1') j
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.a b') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$a') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'x') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'strict') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'strictx $') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'strict x') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$#') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$ 1') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.a#') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$"a"') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.a]') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.a[0]x') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.a[0]1') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.*x') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.**') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$."a"x') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$."a') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$."a\x"') a
-- @step batch
SELECT JSON_VALUE(N'{"a-b":1}', N'$.a-b') a
-- @step batch
SELECT JSON_VALUE(N'{"1a":1}', N'$.1a') a
-- @step batch
SELECT JSON_VALUE(N'{"1":1}', N'$.1') a
-- @step batch
SELECT JSON_VALUE(N'{"a$":1}', N'$.a$') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.ä') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0x]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[a]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0 to ]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0 to') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[1 to2]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0 to 1 2]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0 to 1 to 2]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[1 to 2 x]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[*,1]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[1,*]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[lastx]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[last') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0,1') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[0,last]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[last,0]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[2 to 1') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[last].') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[4294967297]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2]', N'$[9999999999]') a, JSON_VALUE(N'[1,2]', N'$[0000000001]') b, JSON_VALUE(N'[1,2]', N'$[0 to 4294967295]') c
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', N'append $.a', 2) a
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', N'strict append $.a', 2) a
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', N'$ .a', 2) a, JSON_MODIFY(N'{"a":1}', N'$. a', 2) b, JSON_MODIFY(N'{"a":[1]}', N'$.a[ 0 ]', 2) c, JSON_MODIFY(N'{"a":1}', N'append  $.a', 2) d, JSON_MODIFY(N'{"a":[1,2]}', N'$.a[1 to 1]', 9) e
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', N'$.a b', 2) a
-- @step batch
SELECT JSON_MODIFY(N'{"a":[1]}', N'$.a[0 to 1]', 2) a
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', N'$.*', 2) a
-- @step batch
SELECT JSON_MODIFY(N'{"a":[1]}', N'$.a[last]', 2) a
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', N'', 2) a
