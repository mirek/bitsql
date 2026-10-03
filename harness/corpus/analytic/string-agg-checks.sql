-- STRING_AGG checks beyond query/string-agg: separator must be a literal or
-- variable (8733), separator type (8116), no OVER (4113), no DISTINCT
-- (syntax), WITHIN GROUP keys (5308, 5309, 130), ROLLUP (8710), 8000-byte
-- limit (9829), NULL arguments, multi-key WITHIN GROUP.
-- @step setup
CREATE TABLE e (id int NOT NULL PRIMARY KEY, dept varchar(10) NOT NULL, sal int NULL, s nvarchar(10) NULL, v varchar(10) NULL);
INSERT INTO e VALUES (1,'a',100,N'x','x'),(2,'a',200,N'y','y'),(3,'a',NULL,NULL,NULL),(4,'b',50,N'z','z'),(5,'b',70,N'w','w'),(6,'b',70,N'v','v'),(7,'c',NULL,NULL,NULL);
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY s, id DESC) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY sal DESC, s) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY s COLLATE Latin1_General_BIN2) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY id) FROM e WHERE 1 = 0;
-- @step batch
SELECT STRING_AGG(CAST(NULL AS varchar(10)), ',') a, STRING_AGG(N'x', NULL) b FROM e;
-- @step batch
DECLARE @sep nvarchar(5) = N' | '; SELECT STRING_AGG(s, @sep) WITHIN GROUP (ORDER BY id) FROM e;
-- @step batch
SELECT STRING_AGG(sal, ',') a, STRING_AGG(CAST(s AS nvarchar(max)), ',') b, STRING_AGG(v, ',') c FROM e;
-- @step batch
SELECT STRING_AGG(v, N',') FROM e;
-- @step batch
SELECT STRING_AGG(CAST(v AS varchar(max)), N',') FROM e;
-- @step batch
SELECT STRING_AGG(sal, N',') FROM e;
-- @step batch
SELECT STRING_AGG(s, CAST(',' AS varchar(1))) FROM e;
-- @step batch
SELECT STRING_AGG(s, 1) FROM e;
-- @step batch
SELECT STRING_AGG(s, s) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',' + ';') FROM e;
-- @step batch
SELECT STRING_AGG(s, (SELECT ',')) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY s) OVER (PARTITION BY dept) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') OVER () FROM e;
-- @step batch
SELECT STRING_AGG(DISTINCT s, ',') FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY 1) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY CAST(1 AS int)) FROM e;
-- @step batch
SELECT STRING_AGG(s, ',') WITHIN GROUP (ORDER BY (SELECT 1)) FROM e;
-- @step batch
SELECT dept, STRING_AGG(s, ',') WITHIN GROUP (ORDER BY s) FROM e GROUP BY ROLLUP(dept);
-- @step batch
SELECT dept, STRING_AGG(s, ',') FROM e GROUP BY CUBE(dept);
-- @step batch
SELECT STRING_AGG(CAST(REPLICATE('a', 5000) AS varchar(8000)), ',') FROM e;
-- @step batch
SELECT LEN(STRING_AGG(CAST(REPLICATE('a', 5000) AS varchar(max)), ',')) FROM e;
-- @step batch
SELECT STRING_AGG(CAST(REPLICATE(N'a', 1000) AS nvarchar(4000)), N',') FROM e WHERE id < 5;
-- @step batch
SELECT STRING_AGG(CAST(REPLICATE(N'a', 1999) AS nvarchar(4000)), N',') FROM e WHERE id < 4;
