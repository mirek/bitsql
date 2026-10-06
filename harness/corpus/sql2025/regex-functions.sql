-- Oracle probes for the SQL Server 2025 regex family.
-- @step batch
SELECT REGEXP_COUNT('Ab12cd34', '[0-9]+') AS n, REGEXP_SUBSTR('Ab12cd34', '[0-9]+') AS s, REGEXP_INSTR('Ab12cd34', '[0-9]+') AS i, REGEXP_REPLACE('Ab12cd34', '[0-9]+', 'X') AS r;
-- @step batch
SELECT CASE WHEN REGEXP_LIKE('Ab', '^ab$', 'i') THEN 1 ELSE 0 END AS matched;
-- @step batch
SELECT REGEXP_LIKE('Ab', '^ab$', 'i');
-- @step batch
SELECT REGEXP_COUNT('aaa', 'a*') AS n, REGEXP_REPLACE('aaa', 'a*', 'X') AS r;
-- @step batch
SELECT REGEXP_SUBSTR('abc', 'z') AS s, REGEXP_INSTR('abc', 'z') AS i;
-- @step batch
SELECT REGEXP_COUNT('abc', '') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc', '(') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc', 'a', 0) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc', 'a', 1, 'x') AS n;
-- @step batch
SELECT REGEXP_SUBSTR('ab12cd34', '([a-z]+)([0-9]+)', 1, 2, 'c', 2) AS s;
-- @step batch
SELECT REGEXP_REPLACE('ab12cd34', '([a-z]+)([0-9]+)', '\2-\1') AS r;
-- @step batch
SELECT REGEXP_COUNT(NULL, 'a') AS n, REGEXP_SUBSTR('abc', NULL) AS s;
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('a,b,,c', ',');
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab12cd34', '([a-z]+)([0-9]+)');
-- @step batch
SELECT REGEXP_COUNT(CAST('ab' AS varchar(20)), 'a') AS n, REGEXP_SUBSTR(CAST('ab' AS varchar(20)), 'a') AS s, REGEXP_REPLACE(CAST('ab' AS varchar(20)), 'a', 'x') AS r;
