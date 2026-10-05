-- Compound assignment operators (+= -= *= /= %= &= |= ^=) in UPDATE SET,
-- MERGE ... UPDATE SET, SET @v and SELECT @v: each is `x = x op rhs`
-- (compat report 0.1.3: MERGE replaced with the source value; bitwise
-- UPDATE operators computed something else).
-- @step setup
CREATE TABLE dbo.items (id int PRIMARY KEY, value int NULL, s nvarchar(20) NULL, d decimal(6,2) NULL, b tinyint NULL, vb varbinary(4) NULL);
INSERT dbo.items VALUES (1, 1, N'a', 1.5, 6, 0x0F), (2, 10, NULL, NULL, 4, NULL), (3, 10, N'x', 2.25, 6, 0xF0),
  (4, 12, N'y', 3, 6, 0x01), (5, 10, N'z', 4, 4, 0xFF), (6, 10, N'w', 5, 6, 0x10), (7, 4, N'v', 6, 200, 0x11), (8, 6, N'u', 7, 255, 0x22);
-- @step batch
UPDATE dbo.items SET value &= 3 WHERE id = 8;
UPDATE dbo.items SET value |= 3 WHERE id = 7;
UPDATE dbo.items SET value ^= 3 WHERE id = 6;
UPDATE dbo.items SET value += 1, s += N'!', d *= 2 WHERE id IN (1, 2);
UPDATE dbo.items SET value -= 3, b &= 3, vb |= 15 WHERE id IN (3, 4);
UPDATE dbo.items SET value *= 3, b |= 3, vb ^= 15 WHERE id = 5;
UPDATE dbo.items SET value /= 3 WHERE id = 6;
UPDATE dbo.items SET value %= 3 WHERE id = 6;
SELECT id, value, s, d, b, vb FROM dbo.items ORDER BY id;
-- @step batch
UPDATE dbo.items SET vb |= 0x0F WHERE id = 1;
-- @step batch
UPDATE dbo.items SET value /= 3, value %= 3 WHERE id = 6;
-- @step batch
SELECT 1 AS a;
UPDATE dbo.items SET items.Value = 1, dbo.items.VALUE += 2;
-- @step batch
SELECT 1 AS a;
MERGE dbo.items AS x USING (VALUES (1)) s(id) ON x.id = s.id WHEN MATCHED THEN UPDATE SET value = 1, x.value += 2;
-- @step batch
UPDATE dbo.items SET value = 6 WHERE id = 1;
UPDATE dbo.items SET value += NULL WHERE id = 2;
SELECT id, value FROM dbo.items WHERE id IN (1, 2) ORDER BY id;
-- @step batch
UPDATE dbo.items SET b += 100 WHERE id = 8;
-- @step batch
UPDATE dbo.items SET value += 'abc' WHERE id = 1;
-- @step batch
UPDATE dbo.items SET value /= 0 WHERE id = 1;
-- @step batch
UPDATE dbo.items SET d -= 0.005, value *= 2.6 WHERE id = 3;
SELECT d, value FROM dbo.items WHERE id = 3;
-- @step batch
CREATE TABLE dbo.m (id int PRIMARY KEY, op varchar(4) NOT NULL, value int NULL);
INSERT dbo.m VALUES (1, '+=', 1), (2, '-=', 10), (3, '*=', 10), (4, '/=', 12), (5, '%=', 10), (6, '&=', 6), (7, '|=', 4), (8, '^=', 6), (9, '+=', NULL);
MERGE dbo.m WITH (SERIALIZABLE) AS t USING (VALUES (1, -3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value += s.value;
MERGE dbo.m AS t USING (VALUES (2, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value -= s.value;
MERGE dbo.m AS t USING (VALUES (3, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value *= s.value;
MERGE dbo.m AS t USING (VALUES (4, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value /= s.value;
MERGE dbo.m AS t USING (VALUES (5, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value %= s.value;
MERGE dbo.m AS t USING (VALUES (6, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value &= s.value;
MERGE dbo.m AS t USING (VALUES (7, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value |= s.value;
MERGE dbo.m AS t USING (VALUES (8, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value ^= s.value;
MERGE dbo.m AS t USING (VALUES (9, 3)) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value += s.value;
SELECT id, op, value FROM dbo.m ORDER BY id;
-- @step batch
MERGE dbo.m AS t USING (SELECT id, 2 AS value FROM dbo.m) AS s ON t.id = s.id
WHEN MATCHED AND t.id % 2 = 0 THEN UPDATE SET t.value *= s.value, op += 'x'
OUTPUT deleted.value AS old_value, inserted.value AS new_value, inserted.op;
-- @step batch
MERGE dbo.m AS t USING (VALUES (1, 'q')) AS s(id, value) ON t.id = s.id WHEN MATCHED THEN UPDATE SET value += s.value;
-- @step batch
DECLARE @a int = 6, @o int = 4, @x int = 6, @m int = 10, @s nvarchar(10) = N'ab', @n int = NULL, @t tinyint = 250;
SET @a &= 3; SET @o |= 3; SET @x ^= 3; SET @m %= 3; SET @s += N'cd'; SET @n += 1;
SELECT @a AS a, @o AS o, @x AS x, @m AS m, @s AS s, @n AS n;
SELECT @a &= 1, @o |= 8, @x ^= 1, @m *= 5, @s += N'e' FROM (VALUES (1)) v(z);
SELECT @a AS a, @o AS o, @x AS x, @m AS m, @s AS s;
SET @t += 10;
-- @step batch
DECLARE @a int = 6;
SELECT @a ^= value FROM dbo.m WHERE value IS NOT NULL ORDER BY id;
SELECT @a AS a;
-- @step batch
DECLARE @v varbinary(4) = 0x0F;
SET @v |= 0xF0;
-- @step batch
DECLARE @v varbinary(4) = 0x0F;
SET @v |= 240;
SELECT @v AS v;
-- @step batch
DECLARE @i int = 1;
SET @i |= 0xF0;
SELECT @i AS i;
SELECT @i ^= 0x0F;
SELECT @i AS i;
-- @step batch
SELECT CAST(1 AS bit) & CAST(6 AS tinyint) AS bt, CAST(6 AS smallint) | 0x0001 AS sb, '6' ^ CAST(3 AS bigint) AS cb,
  CAST(0x0006 AS varbinary(2)) & 3 AS vi, 6 & NULL AS n, N'7' & CAST(1 AS bit) AS nb;
-- @step batch
SELECT CAST(6 AS decimal(5,0)) & 3;
-- @step batch
SELECT 6.0 | CAST(1 AS float);
-- @step batch
SELECT NULL ^ NULL;
-- @step batch
SELECT 'a' & N'b';
-- @step batch
SELECT CAST(1 AS sql_variant) & 1;
-- @step batch
DECLARE @d decimal(5,0) = 6;
SET @d &= 3;
-- @step batch
DECLARE @s smallint = 32000, @i int = 1000;
SET @s += @i;
-- @step batch
DECLARE @x int = 2147483647;
SET @x += 1;
-- @step batch
UPDATE dbo.items SET d += 9999 WHERE id = 1;
-- @step batch
DECLARE @c varchar(3) = 'abc';
UPDATE dbo.items SET value += @c WHERE id = 1;
-- @step batch
DECLARE @i int = 256, @t tinyint;
SET @t = @i;
