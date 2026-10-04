-- JSON text (JSON_QUERY, JSON_OBJECT, JSON aggregates, FOR JSON with the
-- array wrapper) is embedded as is by FOR JSON, JSON_OBJECT, JSON_ARRAY and
-- JSON_MODIFY, also through derived tables and CTEs; a variable or a
-- WITHOUT_ARRAY_WRAPPER subquery is a plain string.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, j nvarchar(100) NULL);
INSERT dbo.t VALUES (1, N'{"a":[1,2]}'), (2, N'{"a":{"b":"x"}}'), (3, NULL);
-- @step batch
SELECT id, JSON_QUERY(j, '$.a') AS a FROM dbo.t ORDER BY id FOR JSON PATH
-- @step batch
SELECT d.id, d.a FROM (SELECT id, JSON_QUERY(j, '$.a') AS a FROM dbo.t) d ORDER BY d.id FOR JSON PATH, INCLUDE_NULL_VALUES
-- @step batch
WITH c AS (SELECT id, JSON_OBJECT('k':id) AS o FROM dbo.t) SELECT JSON_ARRAY(o) AS arr, JSON_OBJECT('o':o) AS obj FROM c ORDER BY id
-- @step batch
SELECT JSON_MODIFY(N'{"a":1}', '$.a', (SELECT 1 AS x FOR JSON PATH)) AS f1, JSON_MODIFY(N'{"a":1}', '$.a', (SELECT 1 AS x FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS f2
-- @step batch
DECLARE @v nvarchar(max) = JSON_QUERY(N'{"a":[1]}', '$.a'); SELECT JSON_OBJECT('v':@v) AS o, (SELECT @v AS v FOR JSON PATH) AS p
-- @step batch
SELECT (SELECT t.id, (SELECT t2.id AS x FROM dbo.t t2 WHERE t2.id <= t.id ORDER BY t2.id FOR JSON PATH) AS xs FROM dbo.t t ORDER BY t.id FOR JSON PATH) AS nested
