-- Syntax error recovery: after an error SQL Server's parser restarts
-- statements; an error at WITH also reports 319 there, and later errors are
-- reported once three tokens were accepted since the last one.
-- Probed 2026-10-04.
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK) SET a = 1 WHERE a = 2
-- @step batch
DECLARE @t TABLE(a int); MERGE @t WITH (HOLDLOCK) AS x USING (SELECT 1 AS a) AS s ON x.a = s.a WHEN NOT MATCHED THEN INSERT VALUES (s.a);
-- @step batch
DECLARE @t TABLE(a int); MERGE @t WITH (HOLDLOCK) AS x USING (SELECT 1 AS a) s ON x.a = s.a WHEN NOT MATCHED THEN INSERT VALUES (s.a);
-- @step batch
DECLARE @t TABLE(a int); MERGE @t WITH (HOLDLOCK) x USING sys.objects s ON x.a = s.object_id WHEN NOT MATCHED THEN INSERT VALUES (1);
-- @step batch
DECLARE @t TABLE(a int); INSERT INTO @t WITH (TABLOCK) SELECT 1
-- @step batch
DECLARE @t TABLE(a int); INSERT @t WITH (TABLOCK) (a) VALUES (1)
-- @step batch
DECLARE @t TABLE(a int); INSERT INTO @t WITH (TABLOCK) VALUES (1) SELECT 2 x y
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK) SET a = 1; SELECT 1 x y
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK, NOLOCK) SET a = 1
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK)
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH x AS (SELECT 1 AS a) SELECT 1
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (a) AS (SELECT 1 AS a) SELECT 1
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK) SET a = 1 FROM @t x y
-- @step batch
SELECT 1 x y; SELECT 2 a b
-- @step batch
SELECT 1 x y SELECT 2 a b c
-- @step batch
SELECT 1 FROM WHERE; SELECT 2
-- @step batch
SELECT 1 x y; UPDATE
-- @step batch
SELECT * FROM; SELECT 1 AS a b
-- @step batch
SELECT 1 a b; WITH c AS (SELECT 1 AS x) SELECT * FROM c d e
-- @step batch
DELETE FROM sys.objects WITH (ROWLOCK, ; SELECT 1 x y z
-- @step batch
SELECT (1 a b; SELECT 2 x y
-- @step batch
SELECT 1 WITH x AS (SELECT 1 AS a) SELECT * FROM x y z
