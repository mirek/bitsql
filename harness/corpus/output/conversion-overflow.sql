-- Integer conversion overflow messages: numeric/decimal and bigint sources
-- give 8115 state 2 "converting expression"; int/smallint sources to a
-- narrower type give 220; money gives 237. Same in DML assignments.
-- @step setup
CREATE TABLE t(id INT PRIMARY KEY, n INT, s smallint, b tinyint);
INSERT INTO t VALUES(1,1,1,1);
-- @step batch
SELECT CAST(2147483648 AS int) AS c
-- @step batch
SELECT CONVERT(int, 2147483648) AS c
-- @step batch
DECLARE @d decimal(12,2)=3000000000.5; SELECT CAST(@d AS int) AS c
-- @step batch
DECLARE @d decimal(12,2)=300000.5; SELECT CAST(@d AS smallint) AS c
-- @step batch
DECLARE @d decimal(12,2)=300.5; SELECT CAST(@d AS tinyint) AS c
-- @step batch
DECLARE @d decimal(30,2)=30000000000000000000.5; SELECT CAST(@d AS bigint) AS c
-- @step batch
DECLARE @b bigint=3000000000; SELECT CAST(@b AS int) AS c
-- @step batch
DECLARE @b bigint=3000000000; SELECT CAST(@b AS smallint) AS c
-- @step batch
DECLARE @b bigint=3000; SELECT CAST(@b AS tinyint) AS c
-- @step batch
DECLARE @i int=100000; SELECT CAST(@i AS smallint) AS c
-- @step batch
DECLARE @i smallint=1000; SELECT CAST(@i AS tinyint) AS c
-- @step batch
DECLARE @m money=3000000000; SELECT CAST(@m AS int) AS c
-- @step batch
DECLARE @m money=300000; SELECT CAST(@m AS smallint) AS c
-- @step batch
DECLARE @m money=300; SELECT CAST(@m AS tinyint) AS c
-- @step batch
DECLARE @d decimal(12,2)=3000000000.5; DECLARE @i int; SET @i=@d
-- @step batch
UPDATE t SET n=2147483648
-- @step batch
UPDATE t SET n=CAST(2147483648 AS bigint)
-- @step batch
UPDATE t SET s=100000
-- @step batch
UPDATE t SET b=CAST(300 AS bigint)
-- @step batch
INSERT INTO t(id,n) VALUES(2,2147483648)
-- @step batch
SELECT id, n, s, b FROM t
