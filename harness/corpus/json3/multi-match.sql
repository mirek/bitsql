-- Advanced accessors that select several values: `.*`, `[*]`, `[a to b]`.
-- Every candidate element is scanned (validated) entirely, a JSON null
-- among the values ends the search with NULL, missing members inside the
-- elements are skipped even under strict, a strict range past the end of
-- a non-empty array is 13659, and nothing beyond the array is read.
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', N'$.*') a, JSON_VALUE(N'[1,2]', N'$.*') b, JSON_VALUE(N'{"a":1,"b":2}', N'$.*') c, JSON_VALUE(N'{"a":null,"b":2}', N'$.*') d, JSON_VALUE(N'{"a":{"x":1},"b":{"y":2}}', N'$.*.y') e, JSON_QUERY(N'{"a":{"x":1}}', N'$.*') f, JSON_VALUE(N'{"x":{"a":1},"y":[2]}', N'$.*[0]') g
-- @step batch
SELECT JSON_QUERY(N'{"a":{"x":1}}', N'strict $.*') a, JSON_VALUE(N'{"a":1}', N'strict $.*') b
-- @step batch
SELECT JSON_VALUE(N'{}', N'strict $.*') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1,"b":2}', N'strict $.*') a
-- @step batch
SELECT JSON_VALUE(N'{"a":1,"b":x}', N'$.*') a
-- @step batch
SELECT JSON_VALUE(N'[1,null,x]', N'$[0 to 1]') a, JSON_VALUE(N'[1,null,x]', N'$[*]') b, JSON_VALUE(N'[1,null]', N'strict $[*]') c, JSON_QUERY(N'[{"a":1},null]', N'strict $[*]') d, JSON_VALUE(N'{"a":[{"b":1},{"b":null},x]}', N'$.a[*].b') e
-- @step batch
SELECT JSON_VALUE(N'{"a":[1],"b":x}', N'$.a[*]') a, JSON_VALUE(N'{"a":[1,2],"b":x}', N'$.a[0 to 1]') b, JSON_VALUE(N'{"a":[1],"b":x}', N'$.a[5 to 6]') c
-- @step batch
SELECT JSON_VALUE(N'[1,[2,x]]', N'$[*]') a
-- @step batch
SELECT JSON_VALUE(N'[{"a":1},{"a":2,"b":x}]', N'$[*].a') a
-- @step batch
SELECT JSON_VALUE(N'{"a":[{"b":[1,2]},{"b":[3]}]}', N'$.a[*].b[*]') a, JSON_VALUE(N'{"a":[{"b":[1,2]},{"b":[3]}]}', N'$.a[1 to 5].b[*]') b, JSON_QUERY(N'{"a":[{"b":[1,2]},{"c":[3]}]}', N'$.a[0 to 5].b') c, JSON_QUERY(N'{"a":[{"b":[1,2]},{"c":[3]}]}', N'strict $.a[*].b') d, JSON_VALUE(N'{"a":[{"b":1},{"c":2}]}', N'strict $.a[*].b') e, JSON_VALUE(N'[1,{"a":2}]', N'strict $[*].a') f
-- @step batch
SELECT JSON_QUERY(N'{"a":[{"b":[1,2]},{"c":[3]}]}', N'strict $.a[0 to 5].b') a
-- @step batch
SELECT JSON_VALUE(N'{"a":[1,2,3],"b":x}', N'strict $.a[0 to 5]') a
-- @step batch
SELECT JSON_VALUE(N'[1,2,3]', N'strict $[5 to 7]') a
-- @step batch
SELECT JSON_VALUE(N'[[1,2],[3,4]]', N'strict $[*][0 to 2]') a
-- @step batch
SELECT JSON_VALUE(N'[1,[2]]', N'strict $[0 to 1]') a
-- @step batch
SELECT JSON_QUERY(N'{"a":{"x":1}}', N'strict $.a[*]') a
-- @step batch
SELECT JSON_PATH_EXISTS(N'[1,2]', N'$[*]') a, JSON_PATH_EXISTS(N'[]', N'$[*]') b, JSON_PATH_EXISTS(N'[1,2]', N'$[0 to 5]') c, JSON_PATH_EXISTS(N'[1,2]', N'$[5 to 6]') d, JSON_PATH_EXISTS(N'[null]', N'$[*]') e
-- @step batch
SELECT * FROM OPENJSON(N'[[1,2],[3]]', N'$[0 to 0]')
-- @step batch
SELECT * FROM OPENJSON(N'{"a":[1,2]}', N'$.a[0 to 1]')
-- @step batch
SELECT * FROM OPENJSON(N'{"a":[[1],[2]]}', N'$.a') WITH (x int N'$[0 to 0]', y nvarchar(max) N'$[*]' AS JSON)
