-- Aggregates without GROUP BY: result types, nullability flags, empty input,
-- NULL elimination warning 8153 placement, binding errors.
-- @step setup
CREATE TABLE ag (id int NOT NULL, g int NULL, n int NULL, b bigint NULL, s smallint NULL, t tinyint NULL, d decimal(9,3) NULL, f float NULL, r real NULL, m money NULL, v varchar(7) NULL, w nvarchar(20) NULL, k bit NULL, dt datetime2(3) NULL);
INSERT INTO ag VALUES (1, 1, 10, 100, 1, 1, 1.5, 1.5, 1.5, 1.25, 'b', N'x', 1, '2024-01-02'),
 (2, 1, NULL, 200, 2, 2, 2.25, 2.5, 2.5, 2.5, 'a', N'yy', 0, '2024-01-01'),
 (3, 2, 30, NULL, 3, 3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
 (4, NULL, 40, 400, 4, 4, 4.125, 4.0, 4.0, 4.0, 'c', N'z', 1, '2024-01-03');
-- @step batch
SELECT COUNT(*) AS c, COUNT_BIG(*) AS cb, COUNT(n) AS cn, COUNT_BIG(n) AS cbn FROM ag;
-- @step batch
SELECT SUM(id) AS s_int, SUM(b) AS s_big, SUM(s) AS s_small, SUM(t) AS s_tiny, SUM(d) AS s_dec, SUM(f) AS s_float, SUM(r) AS s_real, SUM(m) AS s_money FROM ag WHERE id <> 3;
-- @step batch
SELECT AVG(id) AS a_int, AVG(b) AS a_big, AVG(s) AS a_small, AVG(t) AS a_tiny, AVG(d) AS a_dec, AVG(f) AS a_float, AVG(r) AS a_real, AVG(m) AS a_money FROM ag WHERE id <> 3;
-- @step batch
SELECT MIN(id) AS mi, MAX(id) AS ma, MIN(v) AS minv, MAX(v) AS maxv, MIN(w) AS minw, MAX(w) AS maxw, MIN(dt) AS mindt, MAX(d) AS maxd FROM ag;
-- @step batch
SELECT COUNT(*) AS c, SUM(n) AS s, AVG(n) AS a, MIN(n) AS mi, MAX(n) AS ma, COUNT(n) AS cn FROM ag WHERE id > 100;
-- @step batch
SELECT SUM(n) AS s FROM ag;
SELECT 1 AS after_warning;
-- @step batch
SELECT COUNT(DISTINCT g) AS cdg, SUM(DISTINCT g) AS sdg, AVG(DISTINCT n) AS adn, COUNT(DISTINCT v) AS cdv FROM ag;
-- @step batch
SELECT COUNT(*) + 1 AS expr1, SUM(n) * 2 AS expr2, MAX(n) - MIN(n) AS spread, CAST(AVG(f) AS int) AS castavg FROM ag WHERE n IS NOT NULL;
-- @step batch
SELECT SUM(1) AS s1, COUNT(1) AS c1, MAX('x') AS mx, SUM(CAST(NULL AS int)) AS snull;
-- @step batch
SELECT SUM(k) AS sum_bit FROM ag;
-- @step batch
SELECT SUM(v) AS sum_varchar FROM ag;
-- @step batch
SELECT MIN(k) AS min_bit FROM ag;
-- @step batch
SELECT n FROM ag WHERE SUM(n) > 1;
-- @step batch
SELECT id, COUNT(*) AS c FROM ag;
-- @step batch
SELECT SUM(SUM(n)) AS nested FROM ag;
-- @step batch
SELECT SUM(id) AS s FROM (VALUES (2147483647), (1)) v(id);
SELECT 2 AS after_overflow;
