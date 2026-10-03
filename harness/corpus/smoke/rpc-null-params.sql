-- @step rpc
-- @param @a int = null
-- @param @b nvarchar(10) = null
SELECT @a AS a, @b AS b, CASE WHEN @a IS NULL THEN 1 ELSE 0 END AS a_is_null
