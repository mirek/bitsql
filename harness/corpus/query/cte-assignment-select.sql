-- SELECT @v = ... whose source is a CTE (compat report 0.1.3 #4): one and
-- two CTEs, a recursive CTE, multi-row sources (last row in ORDER BY
-- order wins), compound operators, no matching rows (variable unchanged),
-- inside a procedure and an AFTER INSERT trigger, and FOR JSON/XML.
-- @step batch
DECLARE @n int = 0;
WITH rows AS (SELECT id FROM (VALUES (1), (2)) s(id))
SELECT @n = COUNT(*) FROM rows;
SELECT @n AS value;
-- @step batch
DECLARE @a int = 0, @b varchar(10) = 'x';
WITH r1 AS (SELECT id FROM (VALUES (1), (2), (3)) s(id)),
     r2 AS (SELECT id, CHAR(64 + id) AS c FROM r1 WHERE id > 1)
SELECT @a = SUM(id), @b = MAX(c) FROM r2;
SELECT @a AS a, @b AS b;
-- @step batch
DECLARE @last int = -1;
WITH r AS (SELECT id FROM (VALUES (3), (1), (2)) s(id))
SELECT @last = id FROM r ORDER BY id DESC;
SELECT @last AS last_desc;
WITH r AS (SELECT id FROM (VALUES (3), (1), (2)) s(id))
SELECT @last = id FROM r ORDER BY id;
SELECT @last AS last_asc;
-- @step batch
DECLARE @s int = 100, @none int = 42;
WITH r AS (SELECT id FROM (VALUES (1), (2), (3)) s(id))
SELECT @s += id FROM r;
WITH r AS (SELECT id FROM (VALUES (1)) s(id))
SELECT @none = id FROM r WHERE id > 5;
SELECT @s AS s, @none AS none_, @@ROWCOUNT AS rc;
-- @step batch
DECLARE @total int = 0;
WITH nums AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM nums WHERE n < 10)
SELECT @total = SUM(n) FROM nums;
SELECT @total AS total;
-- @step batch
DECLARE @t int = 0;
WITH r AS (SELECT id FROM (VALUES (1), (2)) s(id))
SELECT @t = id FROM r;
SELECT @@ROWCOUNT AS rc;
-- @step batch
DECLARE @k int = 5;
WITH r AS (SELECT 1 AS id)
SELECT @k = 7;
SELECT @k AS k, @@ROWCOUNT AS rc;
-- @step batch
DECLARE @j nvarchar(max);
WITH r AS (SELECT id FROM (VALUES (1), (2)) s(id))
SELECT @j = (SELECT id FROM r FOR JSON PATH);
SELECT @j AS j;
-- @step batch
DECLARE @j nvarchar(max);
WITH r AS (SELECT id FROM (VALUES (1), (2)) s(id))
SELECT @j = id FROM r FOR JSON PATH;
-- @step batch
DECLARE @x nvarchar(max);
SELECT @x = id FROM (VALUES (1)) s(id) FOR XML PATH('');
-- @step batch
CREATE TABLE dbo.items (id int PRIMARY KEY, value int NOT NULL);
CREATE TABLE dbo.audit (n int, total int);
-- @step batch
CREATE PROCEDURE dbo.count_items @n int OUTPUT AS
BEGIN
  WITH r AS (SELECT id FROM dbo.items)
  SELECT @n = COUNT(*) FROM r;
END;
-- @step batch
CREATE TRIGGER dbo.items_ins ON dbo.items AFTER INSERT AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @n int = 0, @total int = 0;
  WITH ins AS (SELECT id, value FROM inserted),
       big AS (SELECT value FROM ins WHERE value > 0)
  SELECT @n = COUNT(*), @total = SUM(value) FROM big;
  INSERT dbo.audit VALUES (@n, @total);
END;
-- @step batch
INSERT dbo.items VALUES (1, 10), (2, 20), (3, -1);
SELECT n, total FROM dbo.audit;
DECLARE @c int;
EXEC dbo.count_items @c OUTPUT;
SELECT @c AS c;
