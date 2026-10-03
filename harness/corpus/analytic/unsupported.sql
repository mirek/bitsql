-- Analytic behaviour bitsql deliberately reports as unsupported (Emulator
-- errors 50150/50151): TABLESAMPLE sizes other than 0/100 PERCENT (page
-- sampling), APPROX_COUNT_DISTINCT beyond 30 distinct values (SQL Server's
-- HyperLogLog estimate: 99 for 100 values) and under ROLLUP (SQL Server
-- carries the sketch across groups). The captures keep the real answers.
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, v int);
INSERT INTO t SELECT value, value FROM GENERATE_SERIES(1, 1000);
CREATE TABLE e (id int NOT NULL PRIMARY KEY, dept varchar(10) NOT NULL, sal int NULL);
INSERT INTO e VALUES (1,'a',100),(2,'a',200),(3,'a',NULL),(4,'b',50),(5,'b',70),(6,'b',70),(7,'c',NULL);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (50 PERCENT) REPEATABLE (1);
-- @step batch
SELECT COUNT(*) FROM t TABLESAMPLE (1000000 ROWS);
-- @step batch
SELECT APPROX_COUNT_DISTINCT(value) FROM GENERATE_SERIES(1, 100);
-- @step batch
SELECT dept, APPROX_COUNT_DISTINCT(sal) FROM e GROUP BY ROLLUP(dept);
