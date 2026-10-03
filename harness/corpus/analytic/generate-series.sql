-- GENERATE_SERIES(start, stop [, step]): column `value` of the arguments'
-- common type (all integer arguments must have the same type; decimals
-- unify), nullable only when an argument is, descending default step,
-- empty for a step of the wrong sign or NULL arguments, errors 4199, 5373
-- (+206), 8116 (+206), 313, 8144, 195, 208.
-- @step batch
SELECT * FROM GENERATE_SERIES(1, 5);
-- @step batch
SELECT value FROM GENERATE_SERIES(1, 10, 3);
-- @step batch
SELECT value FROM GENERATE_SERIES(10, 1, -4);
-- @step batch
SELECT value FROM GENERATE_SERIES(10, 1);
-- @step batch
SELECT value FROM GENERATE_SERIES(1, 10, -1);
-- @step batch
SELECT value FROM GENERATE_SERIES(5, 5);
-- @step batch
SELECT value FROM GENERATE_SERIES(5, 5, -1);
-- @step batch
SELECT value FROM GENERATE_SERIES(1, NULL);
-- @step batch
SELECT value FROM GENERATE_SERIES(NULL, 3);
-- @step batch
SELECT value FROM GENERATE_SERIES(1, 3, NULL);
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS tinyint), CAST(3 AS tinyint));
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS smallint), CAST(-3 AS smallint), CAST(-2 AS smallint));
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS bigint), CAST(3 AS bigint));
-- @step batch
SELECT * FROM GENERATE_SERIES(1.5, 3.25, 0.5);
-- @step batch
SELECT * FROM GENERATE_SERIES(0.0, 1.0, 0.1);
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS decimal(10,2)), CAST(3 AS decimal(5,1)), CAST(0.5 AS decimal(3,1)));
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS numeric(10,2)), CAST(3 AS numeric(10,2)));
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS decimal(38,0)), CAST(3 AS decimal(38,0)));
-- @step batch
SELECT * FROM GENERATE_SERIES(2.5, 1.0, -0.75);
-- @step batch
SELECT * FROM GENERATE_SERIES(1, 3) AS g;
-- @step batch
SELECT g.value FROM GENERATE_SERIES(1, 3) g;
-- @step batch
SELECT * FROM GENERATE_SERIES(2147483646, 2147483647);
-- @step batch
SELECT * FROM GENERATE_SERIES(2147483640, 2147483647, 5);
-- @step batch
SELECT * FROM GENERATE_SERIES(-2147483648, -2147483646);
-- @step batch
SELECT * FROM GENERATE_SERIES(-2147483646, -2147483648, -1);
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(250 AS tinyint), CAST(255 AS tinyint), CAST(3 AS tinyint));
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(9223372036854775806 AS bigint), CAST(9223372036854775807 AS bigint));
-- @step batch
DECLARE @a int = 3, @b int = 6; SELECT * FROM GENERATE_SERIES(@a, @b);
-- @step batch
SELECT t.x, g.value FROM (VALUES (2),(3)) t(x) CROSS APPLY GENERATE_SERIES(1, t.x) g;
-- @step batch
SELECT * FROM GENERATE_SERIES(1, 3) WHERE value > 1 ORDER BY value DESC;
-- @step batch
SELECT COUNT(*) AS n, SUM(CAST(value AS bigint)) AS s FROM GENERATE_SERIES(1, 100000);
-- @step batch
SELECT value FROM GENERATE_SERIES(1, 3) ORDER BY 1;
-- @step batch
SELECT value FROM GENERATE_SERIES(1, 10, 0);
-- @step batch
SELECT value FROM GENERATE_SERIES(1.0, 2.0, 0.0);
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS smallint), 3);
-- @step batch
SELECT * FROM GENERATE_SERIES(1, CAST(3 AS bigint));
-- @step batch
SELECT * FROM GENERATE_SERIES(1.5, 3);
-- @step batch
SELECT * FROM GENERATE_SERIES(1, 3, 0.5);
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(5 AS tinyint), CAST(0 AS tinyint), -1);
-- @step batch
SELECT * FROM GENERATE_SERIES(1e0, 3e0);
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS money), CAST(3 AS money));
-- @step batch
SELECT * FROM GENERATE_SERIES('1', '3');
-- @step batch
SELECT * FROM GENERATE_SERIES(1, '3');
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST('2024-01-01' AS date), CAST('2024-01-03' AS date));
-- @step batch
SELECT * FROM GENERATE_SERIES(CAST(1 AS bit), CAST(1 AS bit));
-- @step batch
SELECT * FROM GENERATE_SERIES(1, 3) g(n);
-- @step batch
SELECT * FROM GENERATE_SERIES(1);
-- @step batch
SELECT * FROM GENERATE_SERIES(1, 2, 3, 4);
-- @step batch
SELECT * FROM dbo.GENERATE_SERIES(1, 3);
-- @step batch
SELECT GENERATE_SERIES(1, 3);
-- @step batch
SELECT * FROM GENERATE_SERIES(NULL, NULL);
