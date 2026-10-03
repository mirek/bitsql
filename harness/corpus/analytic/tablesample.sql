-- TABLESAMPLE: page-based and nondeterministic in SQL Server. 0 and 100
-- PERCENT are deterministic; validation errors 476, 479, 482, 494, 497 and
-- syntax errors are deterministic too. Other sizes raise an Emulator error
-- in bitsql (not captured here: the oracle's result depends on pages).
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, v int);
INSERT INTO t SELECT value, value FROM GENERATE_SERIES(1, 1000);
CREATE TABLE #tt (a int);
INSERT INTO #tt VALUES (1), (2);
-- @step setup
CREATE VIEW vv AS SELECT * FROM t;
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (100 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE SYSTEM (100 PERCENT) REPEATABLE (7);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (0 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t AS x TABLESAMPLE (100 PERCENT) WITH (NOLOCK) WHERE x.v > 990;
-- @step batch
SELECT COUNT(*) FROM #tt TABLESAMPLE (100 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (100.0 PERCENT) JOIN t AS u TABLESAMPLE (0 PERCENT) ON u.id = t.id;
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (101 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (-1 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (0 ROWS);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (100 PERCENT) REPEATABLE (0);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (100 PERCENT) REPEATABLE (-1);
-- @step batch
DECLARE @p float = 100; SELECT COUNT(*) FROM t TABLESAMPLE (@p PERCENT);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (NULL PERCENT);
-- @step batch
SELECT COUNT(*) FROM vv TABLESAMPLE (100 PERCENT);
-- @step batch
SELECT COUNT(*) FROM (SELECT * FROM t) x TABLESAMPLE (100 PERCENT);
-- @step batch
DECLARE @t TABLE (a int); SELECT COUNT(*) FROM @t TABLESAMPLE (100 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t WITH (NOLOCK) TABLESAMPLE (100 PERCENT);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE BERNOULLI (100 PERCENT);
-- @step batch
DELETE FROM t TABLESAMPLE (100 PERCENT);
