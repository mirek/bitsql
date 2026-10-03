-- ORDER BY with a key that is not a select item (ORDER token ordinal 0)
-- clears fComputed on computed result columns (literal 32 -> 0, nullable
-- expression 33 -> 1); base columns keep their flags.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NULL);
INSERT INTO dbo.t VALUES (1, 10), (2, NULL);
-- @step batch
SELECT a + 1 AS f, id + 1 AS g, 1 AS lit, 'x' AS s, a, CAST(id AS bigint) AS c FROM dbo.t ORDER BY id
-- @step batch
SELECT TOP 5 a + 1 AS f, id + 1 AS g, 1 AS lit FROM dbo.t ORDER BY id
-- @step batch
SELECT a + 1 AS f, id + 1 AS g FROM dbo.t ORDER BY id + 1
-- @step batch
SELECT a + 1 AS f, id FROM dbo.t ORDER BY a + 2
-- @step batch
SELECT a + 1 AS f, ABS(id) AS g FROM dbo.t ORDER BY ABS(id)
-- @step batch
SELECT a + 1 AS f, id FROM dbo.t ORDER BY id
