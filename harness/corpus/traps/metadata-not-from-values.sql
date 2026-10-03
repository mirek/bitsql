-- Trap: COLMETADATA comes from the binder, not row values; empty results keep exact metadata.
-- @step setup
CREATE TABLE md (i int NOT NULL, n int NULL, d decimal(9,3) NULL, s varchar(7) NOT NULL, u nvarchar(max) NULL, b bit NOT NULL);
-- @step batch
SELECT i, n, d, s, u, b FROM md;
SELECT 1 AS lit_int, 2147483648 AS lit_big, 1.50 AS lit_dec, 'ab' AS lit_varchar, N'ab' AS lit_nvarchar, NULL AS lit_null, 1e0 AS lit_float;
SELECT 'a' AS s UNION ALL SELECT 'abcdef';
SELECT ISNULL(NULL, 1) AS isnull_lit, COALESCE(NULL, 1) AS coalesce_lit, CASE WHEN 1 = 0 THEN 1 ELSE 2.5 END AS case_mixed;
SELECT COUNT(*) AS c, COUNT_BIG(*) AS cb, SUM(i) AS si, AVG(i) AS ai, MAX(s) AS ms FROM md;
SELECT @@TRANCOUNT AS trancount, XACT_STATE() AS xact_state, @@ROWCOUNT AS rc, @@ERROR AS err;
