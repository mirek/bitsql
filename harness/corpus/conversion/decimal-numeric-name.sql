-- decimal vs numeric naming of results: arithmetic is numeric when either
-- operand is numeric (an int literal takes the other side's name); CASE,
-- UNION ALL and COALESCE take the first operand's name.
-- @step batch
DECLARE @n numeric(5,0) = 2, @d decimal(5,0) = 1;
SELECT @n + @d AS nd, @d + @n AS dn, @n * @d AS nmd, @d * @n AS dmn, @n - @d AS nsd, @d / @n AS ddn, @n % @d AS nmodd;
-- @step batch
DECLARE @n numeric(5,0) = 2, @d decimal(5,0) = 1;
SELECT CASE WHEN 1=1 THEN @n ELSE @d END AS c1, CASE WHEN 1=1 THEN @d ELSE @n END AS c2, COALESCE(@d, @n) AS c3, ISNULL(@n, @d) AS c4;
-- @step batch
DECLARE @n numeric(5,0) = 2, @d decimal(5,0) = 1;
SELECT @n AS v UNION ALL SELECT @d;
-- @step batch
DECLARE @n numeric(5,0) = 2, @d decimal(5,0) = 1;
SELECT @d AS v UNION ALL SELECT @n;
-- @step batch
DECLARE @d decimal(5,0) = 1;
SELECT @d + 1 AS a, 1 + @d AS b, @d + 1.5 AS c, 1.5 + @d AS d;
