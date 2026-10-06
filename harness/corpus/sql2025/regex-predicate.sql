-- Regex predicates are three-valued search conditions, not scalar expressions.
-- @step batch
SELECT CASE WHEN REGEXP_LIKE('abc','a') THEN 1 ELSE 0 END AS yes, CASE WHEN REGEXP_LIKE('abc','z') THEN 1 ELSE 0 END AS no, CASE WHEN REGEXP_LIKE(NULL,'a') THEN 1 ELSE 0 END AS unknown;
-- @step batch
SELECT x FROM (VALUES ('a'),('b'),(NULL)) p(x) WHERE NOT REGEXP_LIKE(x,'a');
-- @step batch
SELECT x FROM (VALUES ('a'),('b'),(NULL)) p(x) WHERE (REGEXP_LIKE(x,'a') OR x IS NULL);
-- @step batch
SELECT (REGEXP_LIKE('a','a'));
-- @step batch
SELECT COALESCE(REGEXP_LIKE('a','a'),0);
-- @step batch
SELECT 1 WHERE REGEXP_LIKE('a','a') AND NOT REGEXP_LIKE('a','b');
