-- Window-only functions without OVER: 10753 class 15 for the whole batch,
-- state 3 for ranking/distribution, 1 for LAG/LEAD/FIRST_VALUE/LAST_VALUE.
-- @step setup
CREATE TABLE w(a int)
-- @step batch
SELECT ROW_NUMBER() AS r FROM w
-- @step batch
SELECT RANK() AS r FROM w
-- @step batch
SELECT dense_rank() AS r FROM w
-- @step batch
SELECT NTILE(2) AS r FROM w
-- @step batch
SELECT LAG(a) AS r FROM w
-- @step batch
SELECT LEAD(a) AS r FROM w
-- @step batch
SELECT FIRST_VALUE(a) AS r FROM w
-- @step batch
SELECT LAST_VALUE(a) AS r FROM w
-- @step batch
SELECT CUME_DIST() AS r FROM w
-- @step batch
SELECT percent_rank() AS r FROM w
-- @step batch
SELECT 1 AS x; SELECT PERCENT_RANK() AS r FROM w
