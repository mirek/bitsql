-- RPC parameters of several declared types; result metadata follows the declarations.
-- @step rpc
-- @param @bi bigint = "9007199254740993"
-- @param @d decimal(10,3) = 12.345
-- @param @bit bit = true
-- @param @vb varbinary(8) = "0a0b"
-- @param @dt datetime2(3) = "2024-05-06T07:08:09.123Z"
-- @param @g uniqueidentifier = "6F9619FF-8B86-D011-B42D-00C04FD430C8"
SELECT @bi AS bi, @d AS d, @bit AS bit, @vb AS vb, @dt AS dt, @g AS g
