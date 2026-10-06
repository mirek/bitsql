-- Native vector equality, ordering and aggregate restrictions.
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN @v=@v THEN 1 ELSE 0 END AS eq;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT @v+@v AS v;
-- @step batch
CREATE TABLE v(x vector(3)); INSERT INTO v VALUES ('[1,2,3]'),('[1,2,3]');
-- @step batch
SELECT x FROM v ORDER BY x;
-- @step batch
SELECT DISTINCT x FROM v;
-- @step batch
SELECT x,COUNT(*) AS n FROM v GROUP BY x;
-- @step batch
SELECT MIN(x) AS v FROM v;
-- @step batch
SELECT COUNT(x) AS n FROM v;
-- @step batch
SELECT x FROM v UNION SELECT x FROM v;
-- @step batch
SELECT x FROM v UNION ALL SELECT x FROM v;
