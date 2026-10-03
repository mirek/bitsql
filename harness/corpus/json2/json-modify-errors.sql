-- JSON_MODIFY errors: argument types (8116 at compile time), arity (174),
-- strict misses (13608), malformed path (13607) or text (13609), '$' (13619),
-- wildcards (13660), NULL path at run time (8116 state 8).
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'strict $.surname', 'Smith') a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":[1]}', 'strict $.a[5]', 'X') a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'strict append $.a', 'X') a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST('2024-01-01' AS date)) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(0x01 AS varbinary(1))) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(1 AS money)) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier)) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(N'x' AS sql_variant)) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST('2024-01-01' AS datetime2)) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$', N'x') a;
-- @step batch
SELECT JSON_MODIFY(NULL, '$.a', 1) a, JSON_MODIFY(N'{"a":1}', NULL, 1) b;
-- @step batch
SELECT JSON_MODIFY(N'not json', '$.a', 1) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'bad', 1) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.a', 2, 3) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.a') a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b.c', 2) a, JSON_MODIFY(N'{"a":1}', 'strict $.b.c', 2) b;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'strict $.a.b', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'strict $.a[0]', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1} x', '$.a', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1, "b":}', '$.c', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'5', '$.a', 3) a;
-- @step batch
SELECT JSON_MODIFY(N'', '$.a', 3) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'append', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 'APPEND $.a', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":[1]}', '$.a[-1]', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":[1]}', '$.a[*]', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', 1, 2) a;
-- @step batch
SELECT JSON_MODIFY(1, '$.a', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":[1]}', 'strict $.a[1]', NULL) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":{"b":[]}}', 'append $.a.c', 5) a, JSON_MODIFY(N'{"a":{"b":[]}}', 'append strict $.a.c', 5) b;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', CAST(NULL AS nvarchar(10)), 1) b;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.', 2) a;
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', NEWID()) a;
-- @step batch
SELECT JSON_MODIFY(N'"x"', 'append $', 3) a;
