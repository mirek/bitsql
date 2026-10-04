-- RETURNING JSON on JSON_OBJECT / JSON_ARRAY / JSON_ARRAYAGG /
-- JSON_OBJECTAGG: the result is the json type (varchar(max)
-- Latin1_General_100_BIN2_UTF8 on the wire, flags 33), normalized like a
-- CAST to json: duplicate keys keep the first, '/' is not escaped, floats
-- become decimal(38,10) (1e29 is 8115 state 19), money keeps its scale.
-- `RETURNING json(10)` is accepted; other types are 102 state 19.
-- @step setup
CREATE TABLE dbo.ja (id int NOT NULL PRIMARY KEY, g int, k nvarchar(10), v nvarchar(10), n int, j json);
INSERT dbo.ja VALUES (1, 1, N'b', N'y', 2, N'{"x":1}'), (2, 1, N'a', N'x', 1, N'[1]'), (3, 2, N'c', NULL, NULL, NULL);
-- @step batch
SELECT JSON_OBJECT('a':1 RETURNING JSON) AS o, JSON_ARRAY(1 RETURNING JSON) AS a, JSON_OBJECT('a':1 ABSENT ON NULL RETURNING json) AS o2, JSON_OBJECT('a':1 RETURNING json(10)) AS o3
-- @step batch
SELECT JSON_OBJECT('a': 1.5e0, 'd': CAST(2.5 AS real), 'm': CAST(2.5 AS money), 'b': CAST(1 AS bit), 't': CAST('2024-01-02' AS date), 'f': CAST(1e-20 AS float), 'c': 1.50 RETURNING JSON) AS o
-- @step batch
SELECT JSON_OBJECT('g': CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier), 'x': 0x0102, 'dt': CAST('2024-01-02T03:04:05.123' AS datetime2(3)) RETURNING JSON) AS o
-- @step batch
SELECT JSON_OBJECT('a': 1, 'a': 2 RETURNING JSON) AS o, JSON_OBJECT('a': 1, 'a': 2) AS p, JSON_OBJECT('a': NCHAR(1) + N'é/' RETURNING JSON) AS q, JSON_OBJECT('a': NCHAR(1) + N'é/') AS r
-- @step batch
SELECT JSON_ARRAY(1, NULL, 'x' NULL ON NULL RETURNING JSON) AS a, JSON_ARRAY(CAST(12345678901234567890123456789.5 AS decimal(38,1)) RETURNING JSON) AS b, JSON_ARRAY(JSON_QUERY(N'{ "a" : 1 }') RETURNING JSON) AS c
-- @step batch
SELECT JSON_ARRAY(CAST(1e29 AS float) RETURNING JSON) AS a; SELECT 'not reached' AS x
-- @step batch
SELECT JSON_OBJECT('a': CAST(1e300 AS float) RETURNING JSON) AS a
-- @step batch
SELECT JSON_ARRAY(CAST(1e29 AS float)) AS a
-- @step batch
SELECT JSON_ARRAY(RETURNING JSON) AS e
-- @step batch
SELECT JSON_OBJECT('a':1 RETURNING NVARCHAR) AS a
-- @step batch
SELECT JSON_ARRAYAGG(v ORDER BY id RETURNING JSON) AS a, JSON_OBJECTAGG(k:v RETURNING JSON) AS o FROM dbo.ja WHERE g = 1
-- @step batch
SELECT g, JSON_ARRAYAGG(n RETURNING JSON) AS a, JSON_OBJECTAGG(k:n RETURNING JSON) AS o FROM dbo.ja GROUP BY g ORDER BY g
-- @step batch
SELECT JSON_ARRAYAGG(j) AS a, JSON_OBJECTAGG(k:j) AS o FROM dbo.ja
-- @step batch
SELECT JSON_OBJECTAGG(k:v RETURNING JSON) AS o FROM dbo.ja WHERE 1 = 0
-- @step batch
SELECT id, JSON_ARRAYAGG(n RETURNING JSON) OVER (ORDER BY id) AS r FROM dbo.ja ORDER BY id
-- @step batch
SELECT JSON_OBJECTAGG('v':CAST(N'{"x":1}' AS JSON)) AS value
-- @step batch
SELECT JSON_ARRAYAGG(CAST(n AS float) * 1e28 RETURNING JSON) AS a FROM dbo.ja
-- @step batch
EXEC sp_describe_first_result_set N'SELECT JSON_OBJECT(''a'':1 RETURNING JSON) AS o, JSON_ARRAY(1 RETURNING JSON) AS a, JSON_ARRAYAGG(n RETURNING JSON) AS g FROM dbo.ja'
-- @step batch
SELECT JSON_ARRAYAGG(v RETURNING JSON) AS j INTO dbo.ja_into FROM dbo.ja; SELECT c.name, TYPE_NAME(c.system_type_id) AS t, c.max_length FROM sys.columns c WHERE c.object_id = OBJECT_ID('dbo.ja_into')
