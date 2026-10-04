-- json parameters and return values of procedures and functions: arguments
-- convert implicitly from character data (13609 at line 0 for bad text),
-- OUTPUT parameters and RETURNS json work.
-- @step batch
CREATE PROCEDURE dbo.pj @j json, @o json OUTPUT AS BEGIN SET @o = JSON_MODIFY(@j, '$.p', 1); SELECT @j AS j; END
-- @step batch
DECLARE @o json; EXEC dbo.pj N'{"a" : 1}', @o OUTPUT; SELECT @o AS o
-- @step batch
EXEC dbo.pj N'bad', NULL
-- @step batch
CREATE FUNCTION dbo.fj (@j json) RETURNS json AS BEGIN RETURN JSON_MODIFY(@j, '$.f', 1) END
-- @step batch
SELECT dbo.fj(N'{ }') AS f, dbo.fj(NULL) AS n
-- @step batch
EXEC sp_executesql N'SELECT CAST(@p AS json) AS j, @q AS q', N'@p nvarchar(100), @q json', N'[ 1 ]', N'{ "b" : 2 }'
-- @step rpc
-- @param @p nvarchar(100) = "[ 1, 2 ]"
SELECT CAST(@p AS json) AS j
-- @step rpc
-- @param @p nvarchar(100) = "nope"
SELECT CAST(@p AS json) AS j
