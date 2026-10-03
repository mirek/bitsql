-- Stored procedure via RPC by name: return status and an OUTPUT parameter.
-- @step setup
CREATE PROCEDURE dbo.add_one @x int, @y int OUTPUT AS BEGIN SET @y = @x + 1; SELECT @x AS x; RETURN 7 END
-- @step proc dbo.add_one
-- @param @x int = 5
-- @param @y int output
