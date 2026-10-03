-- APPROX_COUNT_DISTINCT (bigint, collation-aware, small cardinalities are
-- exact) and CHECKSUM_AGG (XOR of int values; other types 8117), DISTINCT,
-- OVER, GROUP BY, errors 16200, 4113, 8117.
-- @step setup
CREATE TABLE e (id int NOT NULL PRIMARY KEY, dept varchar(10) NOT NULL, sal int NULL, s nvarchar(10) NULL, b bigint NULL, f float NULL);
INSERT INTO e VALUES (1,'a',100,N'x',1,1.5),(2,'a',200,N'y',2,2.5),(3,'a',NULL,NULL,NULL,NULL),(4,'b',50,N'z',4,1.5),(5,'b',70,N'W',5,7),(6,'b',70,N'w',6,7),(7,'c',NULL,NULL,NULL,NULL);
-- @step batch
SELECT APPROX_COUNT_DISTINCT(sal) a, APPROX_COUNT_DISTINCT(s) b, APPROX_COUNT_DISTINCT(f) c, APPROX_COUNT_DISTINCT(id) d, APPROX_COUNT_DISTINCT(dept) e2, APPROX_COUNT_DISTINCT(b) f2 FROM e;
-- @step batch
SELECT dept, APPROX_COUNT_DISTINCT(sal) FROM e GROUP BY dept ORDER BY dept;
-- @step batch
SELECT APPROX_COUNT_DISTINCT(sal) FROM e WHERE 1 = 0;
-- @step batch
SELECT APPROX_COUNT_DISTINCT(id) AS n FROM e WHERE sal IS NOT NULL;
-- @step batch
SELECT APPROX_COUNT_DISTINCT(value) FROM GENERATE_SERIES(1, 30);
-- @step batch
SELECT APPROX_COUNT_DISTINCT(CAST(value * 7 AS decimal(18,2))) FROM GENERATE_SERIES(1, 30);
-- @step batch
SELECT APPROX_COUNT_DISTINCT(*) FROM e;
-- @step batch
SELECT APPROX_COUNT_DISTINCT(DISTINCT sal) FROM e;
-- @step batch
SELECT APPROX_COUNT_DISTINCT(sal) OVER () FROM e;
-- @step batch
SELECT CHECKSUM_AGG(x) FROM (VALUES (1),(2),(4),(8)) t(x);
-- @step batch
SELECT CHECKSUM_AGG(x) FROM (VALUES (1),(1)) t(x);
-- @step batch
SELECT CHECKSUM_AGG(x) FROM (VALUES (-1),(5)) t(x);
-- @step batch
SELECT CHECKSUM_AGG(x) FROM (VALUES (2147483647),(-2147483648),(123456789)) t(x);
-- @step batch
SELECT CHECKSUM_AGG(DISTINCT x) AS d, CHECKSUM_AGG(ALL x) AS a FROM (VALUES (3),(3),(5)) t(x);
-- @step batch
SELECT CHECKSUM_AGG(sal) OVER (PARTITION BY dept) FROM e ORDER BY id;
-- @step batch
SELECT dept, CHECKSUM_AGG(sal) FROM e GROUP BY dept ORDER BY dept;
-- @step batch
SELECT CHECKSUM_AGG(sal) FROM e WHERE 1 = 0;
-- @step batch
SELECT CHECKSUM_AGG(CAST(NULL AS int)) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(b) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(CAST(sal AS smallint)) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(CAST(sal AS tinyint)) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(s) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(f) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(CAST(1.5 AS decimal(5,1))) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(CAST(1 AS bit)) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(*) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(sal) OVER (ORDER BY id) FROM e;
