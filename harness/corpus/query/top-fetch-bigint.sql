-- TOP and OFFSET/FETCH row counts beyond int: integer literals above
-- 2147483647 type as numeric(p,0) but are accepted, bigint variables too
-- (compat report 0.1.3 findings 2 and 3).
-- @step batch
SELECT TOP 2147483647 id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP 2147483648 id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (9007199254740991) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP 9223372036854775807 id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP 9223372036854775808 id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (99999999999999999999) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (-2147483649) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (2147483648.0) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2147483648 AS bigint)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
DECLARE @n bigint = 9223372036854775807; SELECT TOP (@n) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
DECLARE @n decimal(19,0) = 2147483648; SELECT TOP (@n) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (2147483648) PERCENT id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 2147483647 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 2147483648 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 9007199254740991 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 9223372036854775807 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 9223372036854775808 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 1 ROWS FETCH NEXT 9223372036854775807 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 2147483648 ROWS FETCH NEXT 1 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 9223372036854775807 ROWS;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT -2147483649 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET -2147483649 ROWS;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 2147483648.0 ROWS ONLY;
-- @step batch
DECLARE @n bigint = 2147483648; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @n bigint = 9007199254740991; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @n bigint = 9223372036854775807, @o bigint = 1; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET @o ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @n decimal(19,0) = 2147483648; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @n bigint = 2147483648; SELECT TOP (@n) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
CREATE TABLE #t (id int); INSERT #t VALUES (1), (2);
DELETE TOP (2147483648) FROM #t; SELECT @@ROWCOUNT AS deleted;
-- @step batch
CREATE TABLE #v (id int); INSERT #v VALUES (1), (2);
UPDATE TOP (2147483648) #v SET id = id + 10; SELECT id FROM #v ORDER BY id;
-- @step batch
SELECT TOP ((2147483648)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (2147483648 + 1) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (+2147483648) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (-(2147483648)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (-9223372036854775808) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (-9223372036854775809) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS decimal(5,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS numeric(30,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS numeric(5,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS decimal(30,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (2.5) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS float)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS money)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (ROUND(2.5, 0)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (1 * 2147483648) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (2147483648 / 2) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (ABS(-2147483648)) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS numeric(5,0)) + CAST(1 AS decimal(5,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS decimal(5,0)) * 1) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(2 AS numeric(5,0)) * 1) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(-1 AS numeric(5,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT TOP (CAST(NULL AS numeric(5,0))) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
DECLARE @n numeric(19,0) = 2147483648; SELECT TOP (@n) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
DECLARE @n numeric(5,1) = 1; SELECT TOP (@n) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
DECLARE @d decimal(5,0) = 2; SELECT TOP (@d + 0) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
DECLARE @n bigint = -5; SELECT TOP (@n) id FROM (VALUES (1), (2)) s(id) ORDER BY id;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 0 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT -1 ROWS ONLY;
-- @step batch
SELECT 1 AS before_fetch; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 0 ROWS ONLY;
-- @step batch
SELECT 1 AS before_offset; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET -1 ROWS;
-- @step batch
DECLARE @n bigint = -1; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @n bigint = 0; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @n bigint; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
DECLARE @o bigint = -1; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET @o ROWS;
-- @step batch
DECLARE @o bigint; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET @o ROWS;
-- @step batch
DECLARE @o bigint = 9223372036854775807; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET @o ROWS FETCH NEXT 1 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT (2147483648) ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 2147483648 + 1 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT NULL ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 9223372036854775808 ROWS;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 2147483648 ROWS;
-- @step batch
DECLARE @d decimal(5,0) = 2; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET @d ROWS;
-- @step batch
DECLARE @n numeric(5,0) = 1; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET @n ROWS;
-- @step batch
DECLARE @n numeric(5,0) = 1; SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT @n ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 1.0 ROWS;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET NULL ROWS;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT 2.0 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT CAST(2 AS decimal(5,0)) ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET 0 ROWS FETCH NEXT -9223372036854775809 ROWS ONLY;
-- @step batch
SELECT id FROM (VALUES (1), (2)) s(id) ORDER BY id OFFSET -9223372036854775809 ROWS;
