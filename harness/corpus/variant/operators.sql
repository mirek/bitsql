-- Operators on sql_variant: arithmetic with a numeric operand is 257 (no
-- implicit conversion out of a variant), with anything else 402; modulo is
-- always 402; bitwise 402, or 8117 between two variants; unary minus and
-- ~ are 8117; LIKE is 8116. Comparisons and IS NULL work.
-- @step batch
SELECT CAST(1 AS sql_variant) + 1;
-- @step batch
SELECT 1 + CAST(1 AS sql_variant);
-- @step batch
SELECT CAST(1 AS sql_variant) * 2.5;
-- @step batch
SELECT CAST(1 AS sql_variant) - 1.5e0;
-- @step batch
SELECT CAST(1 AS sql_variant) * CAST(1 AS money);
-- @step batch
SELECT CAST(1 AS sql_variant) / CAST(1 AS bigint);
-- @step batch
SELECT CAST(1 AS sql_variant) + CAST(1 AS sql_variant);
-- @step batch
SELECT CAST(1 AS sql_variant) + N'x';
-- @step batch
SELECT 'a' + CAST(1 AS sql_variant);
-- @step batch
SELECT CAST(1 AS sql_variant) + CAST('a' AS char(1));
-- @step batch
SELECT CAST(1 AS sql_variant) + CAST('2024-01-01' AS date);
-- @step batch
SELECT CAST(1 AS sql_variant) + 0x01;
-- @step batch
SELECT CAST(1 AS sql_variant) + CAST(1 AS bit);
-- @step batch
SELECT CAST(1 AS sql_variant) + NULL;
-- @step batch
SELECT CAST(1 AS sql_variant) % 2;
-- @step batch
SELECT CAST(1 AS sql_variant) & 1;
-- @step batch
SELECT 1 ^ CAST(1 AS sql_variant);
-- @step batch
SELECT CAST(1 AS sql_variant) | CAST(1 AS sql_variant);
-- @step batch
SELECT -CAST(1 AS sql_variant);
-- @step batch
SELECT ~CAST(1 AS sql_variant);
-- @step batch
SELECT 1 WHERE CAST(N'a' AS sql_variant) LIKE 'a';
-- @step batch
SELECT 1 WHERE 'a' LIKE CAST(N'a' AS sql_variant);
-- @step batch
DECLARE @v sql_variant = N'a'; RAISERROR('x %s', 10, 1, @v);
-- @step batch
DECLARE @v sql_variant = N'a';
SELECT CASE WHEN @v IS NULL THEN 1 ELSE 0 END AS isnull_, CASE WHEN @v <> N'b' THEN 1 ELSE 0 END AS ne,
       CASE WHEN @v IN (N'a', 1) THEN 1 ELSE 0 END AS in_list,
       CASE WHEN @v = (SELECT CAST(N'a' AS sql_variant)) THEN 1 ELSE 0 END AS sub;
