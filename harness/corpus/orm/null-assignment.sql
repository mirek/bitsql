-- An untyped NULL assigned to a column or variable whose type int does not
-- convert to explicitly (date, time, datetime2, datetimeoffset,
-- uniqueidentifier): TypeORM's restore() runs `UPDATE ... SET "deletedAt" =
-- NULL`; the emulator raised 529. A typed int source stays a compile error.
-- @step setup
CREATE TABLE b (id int, d datetime2 NULL, dt datetime NULL, dd date NULL, t time NULL, o datetimeoffset NULL, g uniqueidentifier NULL, x xml NULL, v sql_variant NULL);
INSERT INTO b VALUES (1, '2020-01-01', '2020-01-01', '2020-01-01', '10:00', '2020-01-01', NEWID(), '<a/>', 1);
-- @step batch
UPDATE b SET d = NULL;
UPDATE b SET dt = NULL, dd = NULL, t = NULL, o = NULL, g = NULL, x = NULL, v = NULL;
INSERT INTO b (id, d, dd, t, o, g) VALUES (2, NULL, NULL, NULL, NULL, NULL);
INSERT INTO b (id, d) SELECT 3, NULL;
UPDATE b SET d = NULL OUTPUT inserted.id, inserted.d WHERE id = 3;
MERGE b AS tgt USING (SELECT 2 AS id) AS src ON tgt.id = src.id WHEN MATCHED THEN UPDATE SET o = NULL, g = NULL;
SELECT id, d, dt, dd, t, o, g, CAST(x AS nvarchar(10)) AS x, v FROM b ORDER BY id;
-- @step batch
DECLARE @x datetime2 = '2020-01-01', @g uniqueidentifier = NEWID(), @o datetimeoffset = SYSDATETIMEOFFSET();
SET @x = NULL;
SELECT @g = NULL, @o = NULL;
SELECT @x AS x, @g AS g, @o AS o;
-- @step batch
DECLARE @i int;
UPDATE b SET d = @i;
-- @step batch
UPDATE b SET d = 1;
-- @step rpc
-- @param @p0 varchar(50) = "x"
UPDATE b SET d = NULL, dd = NULL WHERE id = 1 AND @p0 = 'x'
