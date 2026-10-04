-- Two CREATE TABLEs of one temp table name in a batch fail the whole batch
-- at compile time (2714 state 1, line of the second), also across
-- branches, after a DROP, for ## tables and case-insensitively; permanent
-- tables fail at run time (state 6). Nested EXEC strings compile alone.
-- @step batch
SELECT 1 AS first;
CREATE TABLE #d(a int);

CREATE TABLE #d(a int)
-- @step batch
SELECT 1 AS first; CREATE TABLE #e(a int); DROP TABLE #e; CREATE TABLE #e(b int)
-- @step batch
SELECT 1 AS first; IF 1 = 0 CREATE TABLE #f(a int) ELSE CREATE TABLE #f(b int)
-- @step batch
SELECT 1 AS first; CREATE TABLE dup_perm(a int); CREATE TABLE dup_perm(a int)
-- @step batch
SELECT 1 AS first; CREATE TABLE ##gd(a int); CREATE TABLE ##gd(a int)
-- @step batch
SELECT 1 AS first; CREATE TABLE #i(a int); SELECT a FROM #i; CREATE TABLE #I(a int)
