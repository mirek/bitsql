-- Table variables take no table hints: 319 after FROM @t, 156 near 'WITH'
-- for a DML target (SQL Server then reports 319 too).
-- @step batch
DECLARE @t TABLE(a int); DELETE FROM @t WITH (ROWLOCK)
-- @step batch
DECLARE @t TABLE(a int); INSERT INTO @t WITH (TABLOCK) VALUES (1)
-- @step batch
DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK) SET a = 1
-- @step batch
DECLARE @t TABLE(a int); SELECT * FROM @t x WITH (NOLOCK)
-- @step batch
DECLARE @t TABLE(a int); SELECT * FROM @t AS x WITH (NOLOCK);
-- @step batch
DECLARE @t TABLE(a int); SELECT * FROM @t WITH (NOLOCK);
-- @step batch
DECLARE @t TABLE(a int); MERGE @t WITH (HOLDLOCK) AS x USING (SELECT 1 AS a) s ON x.a = s.a WHEN NOT MATCHED THEN INSERT VALUES (s.a);
