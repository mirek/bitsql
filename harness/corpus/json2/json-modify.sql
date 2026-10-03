-- JSON_MODIFY: replace, insert (lax), delete with NULL (lax) or set null
-- (strict), append, nested paths, arrays; JSON values from JSON_QUERY,
-- JSON_MODIFY, JSON_OBJECT and JSON_ARRAY are inserted raw.
-- @step batch
DECLARE @j nvarchar(max) = N'{"name":"John","skills":["C#","SQL"],"age":30,"addr":{"city":"X"}}';
SELECT JSON_MODIFY(@j, '$.name', 'Mike') a, JSON_MODIFY(@j, '$.surname', 'Smith') b, JSON_MODIFY(@j, '$.name', NULL) c, JSON_MODIFY(@j, 'strict $.name', NULL) d, JSON_MODIFY(@j, 'append $.skills', 'Azure') e;
SELECT JSON_MODIFY(@j, '$.skills', JSON_QUERY('["a","b"]')) a, JSON_MODIFY(@j, '$.skills', '["a","b"]') b, JSON_MODIFY(@j, '$.age', 31) c, JSON_MODIFY(@j, '$.age', 31.5) d, JSON_MODIFY(@j, '$.addr.city', N'Y') e, JSON_MODIFY(@j, '$.addr.zip', 123) f;
SELECT JSON_MODIFY(@j, '$.skills[0]', 'X') a, JSON_MODIFY(@j, '$.skills[5]', 'X') b, JSON_MODIFY(@j, 'append $.newarr', 'X') c, JSON_MODIFY(@j, 'append $.name', 'X') d, JSON_MODIFY(@j, '$.skills[1]', NULL) e, JSON_MODIFY(@j, 'append strict $.skills', 'X') f;
-- @step batch
SELECT JSON_MODIFY(N'[1,2,3]', '$[1]', N'x') a, JSON_MODIFY(N'[1,2,3]', 'append $', 4) b, JSON_MODIFY(N'[1,2,3]', '$[1]', NULL) c, JSON_MODIFY(N'[1,2,3]', 'strict $[1]', NULL) d;
SELECT JSON_MODIFY(N'{"a":1}', '$.a', N'x"y') a, JSON_MODIFY(N'{"a" : 1 , "b" : [ 1 , 2 ] }', '$.a', 5) b, JSON_MODIFY(N'{ "a":{ "c" : 2 } }', '$.a.c', 3) c, JSON_MODIFY(N'{"a":1,"a":2}', '$.a', 5) d;
SELECT JSON_MODIFY(N'{"a":{"b":1}}', '$.a', JSON_MODIFY(N'{"b":1}', '$.b', 2)) a, JSON_MODIFY(N'{"a":1}', '$.a', JSON_OBJECT('x':1)) b, JSON_MODIFY(N'{"a":1}', '$.a', JSON_ARRAY(1)) d;
SELECT JSON_MODIFY(CAST('{"a":1}' AS varchar(100)), '$.a', 2) a, JSON_MODIFY(CAST(N'{"a":1}' AS nvarchar(50)), '$.a', 2) b, JSON_MODIFY(N'{"a b":1}', '$."a b"', 2) c, JSON_MODIFY(N'{"a":1}', 'strict $."a"', 2) d;
DECLARE @p nvarchar(20) = N'$.a'; SELECT JSON_MODIFY(N'{"a":1}', @p, 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.a.b', 2) a, JSON_MODIFY(N'{"a":[1]}', '$.a[0].b', 2) b, JSON_MODIFY(N'{"a":1}', 'lax $.a', 2) c, JSON_MODIFY(N'{"a":1}', 'append lax $.a', 2) d, JSON_MODIFY(N'{"a":1}', '$.x.y.z', 2) e, JSON_MODIFY(N'{"a":{"b":{"c":1}}}', '$.a.b.d', 2) f;
SELECT JSON_MODIFY(N'{"a":1}', 'append $.a', NULL) a, JSON_MODIFY(N'{"a":[]}', 'append $.a', NULL) b, JSON_MODIFY(N'{"a":[]}', 'append strict $.a', NULL) c, JSON_MODIFY(N'{"a":1}', '$.b', NULL) d, JSON_MODIFY(N'{"a":1}', '$.b', N'') e;
SELECT JSON_MODIFY(N'{"a":1}', '$.a[0]', 2) a, JSON_MODIFY(N'[1]', '$.a', 2) b, JSON_MODIFY(N'[1]', '$[0].x', 2) c, JSON_MODIFY(N'{"a":1}', 'append $', 3) d, JSON_MODIFY(N'[[1,2]]', '$[0][1]', 9) e;
SELECT JSON_MODIFY(N'{"a":1}', 'append $.a', JSON_QUERY('[2]')) a, JSON_MODIFY(N'{"a":[1]}', 'append $.a', JSON_QUERY('[2]')) b, JSON_MODIFY(N'{"a":[1]}', 'append $.a', '[2]') c, JSON_MODIFY(N'{"a":[1]}', 'append $.a[0]', 5) d, JSON_MODIFY(N'{"a":[[1]]}', 'append $.a[0]', 5) e;
SELECT JSON_MODIFY(N'[1,2,3]', '$[0]', NULL) a, JSON_MODIFY(N'[1,2,3]', '$[2]', NULL) b, JSON_MODIFY(N'{"a":{"b":1}}', 'strict $.a.b', NULL) c, JSON_MODIFY(N'{"a":[]}', 'strict $.a', NULL) d;
SELECT JSON_MODIFY(N'{"a":1}', ' append $.a', 2) a, JSON_MODIFY(N'{"a":[1]}', 'append  strict  $.a', 2) b, JSON_MODIFY(CAST(NULL AS nvarchar(10)), '$.a', 1) c;
DECLARE @v nvarchar(max) = JSON_QUERY(N'[1]'); SELECT JSON_MODIFY(N'{"a":1}', '$.a', @v) a, JSON_MODIFY(N'{"a":1}', '$.a', JSON_VALUE(N'{"x":"[1]"}', '$.x')) b;
SELECT JSON_MODIFY(JSON_MODIFY(N'{"a":1}', '$.b', 2), '$.c', 3) a;
