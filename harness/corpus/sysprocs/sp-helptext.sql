-- sp_helptext: module text split into lines (procedures, views,
-- functions, triggers), objects without text (15197), missing objects
-- (15009).
-- @step setup
CREATE TABLE dbo.heap (a int);
-- @step setup
CREATE PROCEDURE dbo.p1 @a int AS
SELECT @a AS a;
-- @step setup
CREATE VIEW dbo.v
AS
  SELECT a
  FROM dbo.heap;
-- @step setup
CREATE FUNCTION dbo.f (@x int) RETURNS int AS BEGIN RETURN @x + 1 END;
-- @step setup
CREATE TRIGGER dbo.tr ON dbo.heap AFTER INSERT AS
BEGIN
  SET NOCOUNT ON;
END;
-- @step setup
DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
DECLARE @sql nvarchar(max) = N'CREATE PROCEDURE dbo.p2 AS' + @crlf + N'SELECT 1 AS one;' + @crlf + @crlf + N'-- ' + REPLICATE(N'x', 300) + @crlf + N'SELECT 2 AS two' + NCHAR(13) + N'SELECT 3 AS three' + NCHAR(10) + N'SELECT 4 AS four;' + @crlf;
EXEC (@sql);
-- @step batch
EXEC sp_helptext 'dbo.p1';
-- @step batch
EXEC sp_helptext 'dbo.p2';
-- @step batch
EXEC sp_helptext 'v';
-- @step batch
EXEC sp_helptext @objname = N'dbo.f';
-- @step batch
EXEC sp_helptext 'dbo.tr';
-- @step batch
EXEC sp_helptext 'heap';
-- @step batch
EXEC sp_helptext 'nothing';
-- @step proc sp_helptext
-- @param @objname nvarchar(776) = "dbo.p1"
