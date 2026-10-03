-- READONLY table-valued parameters of procedures, functions and
-- sp_executesql in batches: passing table variables, the empty default,
-- 352 (missing READONLY), 10700 (modification), 206 (scalar argument).
-- @step setup
CREATE TYPE dbo.IdList AS TABLE (id int NOT NULL PRIMARY KEY, label nvarchar(10) NULL);
CREATE TABLE dbo.items (id int NOT NULL PRIMARY KEY, v nvarchar(10) NOT NULL);
INSERT INTO dbo.items VALUES (1, N'one'), (2, N'two'), (3, N'three');
-- @step batch
CREATE PROCEDURE dbo.pick @ids dbo.IdList READONLY, @extra int = 0 AS
SELECT i.id, i.v, x.label FROM dbo.items i JOIN @ids x ON x.id = i.id ORDER BY i.id;
SELECT COUNT(*) + @extra AS n FROM @ids;
-- @step batch
CREATE FUNCTION dbo.f_count (@ids dbo.IdList READONLY) RETURNS int AS BEGIN RETURN (SELECT COUNT(*) FROM @ids) END;
-- @step batch
CREATE FUNCTION dbo.f_rows (@ids dbo.IdList READONLY) RETURNS TABLE AS RETURN SELECT id * 10 AS x FROM @ids;
-- @step batch
DECLARE @t dbo.IdList;
INSERT INTO @t VALUES (1, N'a'), (3, NULL);
EXEC dbo.pick @t;
EXEC dbo.pick @ids = @t, @extra = 10;
EXEC dbo.pick;
SELECT dbo.f_count(@t) AS c;
SELECT * FROM dbo.f_rows(@t) ORDER BY x;
EXEC sp_executesql N'SELECT SUM(id) AS s FROM @p', N'@p dbo.IdList READONLY', @t;
EXEC sp_executesql N'SELECT COUNT(*) AS c FROM @p', N'@p IdList READONLY', @p = @t;
-- @step batch
DECLARE @i int = 1;
EXEC dbo.pick @i;
-- @step batch
DECLARE @t dbo.IdList;
EXEC sp_executesql N'DELETE FROM @p', N'@p dbo.IdList READONLY', @t;
EXEC sp_executesql N'SELECT 1', N'@p dbo.IdList', @t;
SELECT 2 AS after_errors;
-- @step batch
CREATE PROCEDURE dbo.p2 @ids dbo.IdList AS SELECT COUNT(*) AS n FROM @ids;
-- @step batch
CREATE PROCEDURE dbo.p3 @ids dbo.IdList READONLY AS INSERT INTO @ids VALUES (1, NULL);
-- @step batch
CREATE PROCEDURE dbo.p4 @ids dbo.IdList READONLY AS DELETE FROM @ids;
-- @step batch
CREATE PROCEDURE dbo.p5 @ids dbo.IdList READONLY AS UPDATE @ids SET label = N'z';
-- @step batch
CREATE FUNCTION dbo.f_bad (@ids dbo.IdList) RETURNS int AS BEGIN RETURN 1 END;
-- @step batch
CREATE PROCEDURE dbo.p6 @x int READONLY AS SELECT @x;
-- @step batch
CREATE PROCEDURE dbo.p7 @ids dbo.IdList READONLY OUTPUT AS SELECT 1;
-- @step batch
CREATE PROCEDURE dbo.p8 @ids dbo.IdList READONLY = NULL AS SELECT 1;
-- @step batch
DECLARE @t dbo.IdList;
INSERT INTO @t VALUES (2, N'b');
EXEC dbo.pick @t, 1;
-- @step batch
SELECT name, is_readonly, system_type_id, user_type_id, max_length FROM sys.parameters WHERE object_id = OBJECT_ID('dbo.pick') ORDER BY parameter_id;
