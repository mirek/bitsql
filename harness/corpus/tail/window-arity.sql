-- Window-only functions with the wrong number of arguments: 4114 (exactly n),
-- 10755 for LAG/LEAD, class 15, for the whole batch.
-- @step setup
CREATE TABLE r(a int)
-- @step batch
SELECT RANK(a) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT DENSE_RANK(a, a) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT NTILE() OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT NTILE(1, 2) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT ROW_NUMBER(1) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT PERCENT_RANK(a) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT CUME_DIST(a) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT LAG() OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT 1 AS x; SELECT ROW_NUMBER(a) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT row_number(a) OVER(ORDER BY a) AS r FROM r
-- @step batch
SELECT lead(a, 1, 2, 3) OVER(ORDER BY a) AS r FROM r
