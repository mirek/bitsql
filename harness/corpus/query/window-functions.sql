-- Window functions: ranking, LAG/LEAD, FIRST_VALUE/LAST_VALUE, NTILE,
-- aggregates OVER with PARTITION BY / ORDER BY / ROWS frames.
-- @step setup
CREATE TABLE wf (id int NOT NULL, g int NULL, n int NULL, v varchar(5) NULL);
INSERT INTO wf VALUES (1, 1, 10, 'a'), (2, 1, 20, 'b'), (3, 1, 20, 'c'), (4, 2, 5, 'd'), (5, 2, NULL, 'e'), (6, NULL, 7, 'f');
-- @step batch
SELECT id, ROW_NUMBER() OVER (ORDER BY id DESC) AS rn, RANK() OVER (ORDER BY n) AS rk, DENSE_RANK() OVER (ORDER BY n) AS drk FROM wf ORDER BY id;
-- @step batch
SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY n, id) AS rn, NTILE(2) OVER (PARTITION BY g ORDER BY id) AS nt FROM wf ORDER BY id;
-- @step batch
SELECT id, LAG(n) OVER (ORDER BY id) AS lg, LEAD(n, 2, -1) OVER (ORDER BY id) AS ld, LAG(v, 1, 'zz') OVER (PARTITION BY g ORDER BY id) AS lv FROM wf ORDER BY id;
-- @step batch
SELECT id, FIRST_VALUE(n) OVER (PARTITION BY g ORDER BY id) AS fv, LAST_VALUE(n) OVER (PARTITION BY g ORDER BY id) AS lv, LAST_VALUE(n) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS lv_all FROM wf ORDER BY id;
-- @step batch
SELECT id, SUM(n) OVER () AS total, SUM(n) OVER (PARTITION BY g) AS by_g, COUNT(*) OVER (PARTITION BY g) AS cnt, AVG(n) OVER (PARTITION BY g) AS av FROM wf ORDER BY id;
-- @step batch
SELECT id, SUM(n) OVER (ORDER BY n) AS running_range, SUM(n) OVER (ORDER BY n ROWS UNBOUNDED PRECEDING) AS running_rows, SUM(n) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS moving, MAX(n) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING) AS ahead FROM wf ORDER BY id;
-- @step batch
SELECT g, SUM(n) AS s, RANK() OVER (ORDER BY SUM(n) DESC) AS r, SUM(SUM(n)) OVER () AS grand FROM wf GROUP BY g ORDER BY g;
-- @step batch
SELECT id FROM wf WHERE ROW_NUMBER() OVER (ORDER BY id) = 1;
-- @step batch
SELECT ROW_NUMBER() OVER () AS rn FROM wf;
-- @step batch
SELECT id, PERCENT_RANK() OVER (ORDER BY id) AS pr, CUME_DIST() OVER (ORDER BY id) AS cd FROM wf ORDER BY id;
