-- JSON functions over json values: JSON_VALUE is nvarchar(4000), JSON_QUERY
-- and JSON_MODIFY return json (re-normalized: a float value becomes
-- decimal(38,10)), ISJSON / JSON_PATH_EXISTS / OPENJSON work on the
-- normalized text. Strict errors use other states for json documents
-- (13608 state 5, OPENJSON 7 / WITH 8, 13623/13624 state 2, 13621 state 2,
-- 13611 state 3). JSON_OBJECT / JSON_ARRAY / FOR JSON embed json values
-- raw, and a json argument makes the constructor return json. JSON_MODIFY
-- of character text rejects a json new value (8116). OPENJSON WITH json
-- columns: AS JSON keeps containers, otherwise a string value is parsed.
-- @step setup
CREATE TABLE dbo.tj (id int NOT NULL PRIMARY KEY, j json NULL);
INSERT dbo.tj (id, j) VALUES (1, N'{"a":1}'), (2, '[1, 2]'), (3, NULL), (4, N'[7]');
-- @step batch
SELECT id, JSON_VALUE(j, '$.a') AS v, JSON_QUERY(j, '$') AS q, ISJSON(j) AS i, JSON_MODIFY(j, '$.z', 1) AS m, JSON_PATH_EXISTS(j, '$[0]') AS p FROM dbo.tj ORDER BY id
-- @step batch
SELECT t.id, o.[key], o.value, o.type FROM dbo.tj t CROSS APPLY OPENJSON(t.j) o ORDER BY t.id, o.[key]
-- @step batch
SELECT id, j FROM dbo.tj ORDER BY id FOR JSON PATH
-- @step batch
DECLARE @j json = N'{"a":1}'; SELECT @j AS j FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":"x"}]}'; SELECT JSON_VALUE(@j, '$.a[1].b') AS v, JSON_QUERY(@j, '$.a') AS q, JSON_QUERY(@j, '$.a[1]') AS q2, ISJSON(@j, OBJECT) AS o, ISJSON(@j, ARRAY) AS a, ISJSON(@j, SCALAR) AS s, ISJSON(@j, VALUE) AS w
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_QUERY(@j, '$.a[*]') AS v, JSON_VALUE(@j, '$.a[*]') AS w, JSON_PATH_EXISTS(@j, '$.a[1].b') AS e, JSON_PATH_EXISTS(@j, '$.q') AS f
-- @step batch
DECLARE @j json; SELECT JSON_VALUE(@j, '$.a') AS v, JSON_QUERY(@j) AS q, ISJSON(@j) AS i, JSON_MODIFY(@j, '$.a', 1) AS m, JSON_PATH_EXISTS(@j, '$') AS p
-- @step batch
SELECT JSON_QUERY(CAST(N'{"a":[1, 2]}' AS json), '$') AS a, JSON_QUERY(N'{"a":[1, 2]}', '$') AS b, JSON_VALUE(CAST(N'{"a":1.0e1}' AS json), '$.a') AS c
-- @step batch
DECLARE @j json = N'{"a":[1]}'; SELECT JSON_MODIFY(@j, 'append $.a', 2) AS m, JSON_MODIFY(@j, '$.b', JSON_QUERY(N'[1, 2]')) AS m2, JSON_MODIFY(@j, '$.c', CAST(N'{"x" : 1}' AS json)) AS m3, JSON_MODIFY(@j, '$.a', NULL) AS m4, JSON_MODIFY(@j, '$.d', 1e2) AS m5, JSON_MODIFY(@j, '$.e', N'{bad') AS m6
-- @step batch
DECLARE @j json = N'{"a":[1]}'; SET @j = JSON_MODIFY(@j, '$.b', N'x y'); SELECT @j AS j
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.b', CAST(N'[1]' AS json)) AS m
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_VALUE(@j, 'strict $.zz') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_VALUE(@j, 'strict $.a') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_VALUE(@j, 'strict $.a[*]') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_QUERY(@j, 'strict $.zz') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_QUERY(@j, 'strict $.s') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_QUERY(@j, 'strict $.a[*]') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_QUERY(@j, 'strict $.a[0 to 5]') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_MODIFY(@j, 'strict $.zz', 1) AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_MODIFY(@j, 'append strict $.s', 1) AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT * FROM OPENJSON(@j, 'strict $.zz')
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT * FROM OPENJSON(@j, 'strict $.s')
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT * FROM OPENJSON(@j) WITH (z int 'strict $.zz')
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; SELECT JSON_VALUE(@j, '$.') AS v
-- @step batch
DECLARE @j json = N'{"a":[1,{"b":2}],"s":"x"}'; DECLARE @p nvarchar(10); SELECT JSON_QUERY(@j, @p) AS v
-- @step batch
DECLARE @j json = N'{"a":[1]}'; SELECT * FROM OPENJSON(@j) WITH (a nvarchar(max) '$.a' AS JSON, b int '$.a[0]')
-- @step batch
DECLARE @j json = N'{"a":[1]}'; SELECT * FROM OPENJSON(@j, '$.a')
-- @step batch
SELECT * FROM OPENJSON(N'{"x":{"y":1},"s":"t","n":1,"q":"[1, 2]"}') WITH (x json '$.x', x2 json '$.x' AS JSON, n json '$.n', q json '$.q')
-- @step batch
SELECT * FROM OPENJSON(N'{"x":{"y":1},"s":"t"}') WITH (s json '$.s' AS JSON)
-- @step batch
SELECT * FROM OPENJSON(N'{"x":{"y":1},"s":"t"}') WITH (s json '$.s')
-- @step batch
DECLARE @j json = N'{"a":[1]}'; SELECT JSON_OBJECT('k': @j) AS o, JSON_ARRAY(@j, 1) AS a, JSON_OBJECT('k': @j RETURNING JSON) AS o2, JSON_OBJECT('k': JSON_QUERY(@j)) AS o3
-- @step batch
SELECT JSON_OBJECT('j':CAST(N'{"x":1}' AS JSON)) AS o, JSON_ARRAY(CAST(N'[1]' AS JSON)) AS a
-- @step batch
SELECT JSON_ARRAYAGG(j) AS a, JSON_OBJECTAGG(CAST(id AS nvarchar(10)) : j) AS o FROM dbo.tj
