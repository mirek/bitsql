-- SELECT INTO (table creation, metadata of the new table, rowcount) and
-- SELECT @v = expr FROM ... (last row wins, no rows keeps the value).
-- @step setup
CREATE TABLE si (id int NOT NULL, v varchar(5) NULL, d decimal(5,2) NULL);
INSERT INTO si VALUES (1, 'a', 1.5), (2, 'b', NULL), (3, NULL, 3.25);
-- @step batch
SELECT id, v, d, id * 2 AS twice INTO si_copy FROM si WHERE id < 3;
SELECT * FROM si_copy ORDER BY id;
-- @step batch
SELECT id, v INTO #tmp FROM si;
SELECT COUNT(*) AS c FROM #tmp;
-- @step batch
SELECT id INTO si_copy FROM si;
-- @step batch
DECLARE @x int = -1, @v varchar(5) = 'z';
SELECT @x = id, @v = v FROM si ORDER BY id;
SELECT @x AS x, @v AS v, @@ROWCOUNT AS rc;
-- @step batch
DECLARE @x int = -1;
SELECT @x = id FROM si WHERE id > 100;
SELECT @x AS x, @@ROWCOUNT AS rc;
-- @step batch
DECLARE @s int = 0;
SELECT @s = @s + id FROM si;
SELECT @s AS s;
-- @step batch
DECLARE @c int;
SELECT @c = COUNT(*) FROM si WHERE v IS NOT NULL;
SELECT @c AS c;
