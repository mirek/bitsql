-- Database-qualified temp table names: INFO 2701 per reference at batch
-- compile (any database name, as written; line of the reference), again
-- when a deferred statement is recompiled; 208 names the bare temp table
-- with state 0.
-- @step setup
CREATE TABLE #foo(id int NOT NULL PRIMARY KEY, v varchar(5))
-- @step batch
SELECT id FROM model..#foo
-- @step batch
SELECT id FROM nosuchdb..#foo
-- @step batch
SELECT id FROM tempdb..#foo; SELECT id FROM TEMPDB.dbo.#foo
-- @step batch
INSERT tempdb..#foo VALUES (1, 'a'); UPDATE tempdb..#foo SET v = 'b'; DELETE tempdb..#foo
-- @step batch
SELECT 1 AS one; SELECT id FROM tempdb..#nosuch; SELECT 2 AS two
-- @step batch
SELECT id FROM tempdb..#nosuch; SELECT id FROM tempdb..#foo
-- @step batch
SELECT 1 AS one;

SELECT id
FROM tempdb..#foo;
SELECT 2 AS two
-- @step batch
SELECT 1 AS one;
CREATE TABLE #m(a int);
IF 1 = 1
BEGIN
  SELECT 3 AS three;
  SELECT a FROM tempdb..#m;
END
DROP TABLE #m
-- @step batch
SELECT id FROM tempdb..#foo WHERE id IN (SELECT id FROM tempdb..#foo)
-- @step batch
EXEC('SELECT id FROM tempdb..#foo')
-- @step batch
DECLARE @x int = (SELECT COUNT(*) FROM tempdb..#foo); SELECT @x AS x
-- @step batch
SELECT id FROM tempdb.sys.#foo
-- @step batch
SELECT CASE WHEN OBJECT_ID('tempdb..#foo') IS NULL THEN 0 ELSE 1 END AS found, OBJECT_ID('#foo') AS unqualified
-- @step batch
INSERT INTO dbo.#missing VALUES (1)
