-- RPC requests SQL Server rejects while decoding, keeping the connection.
-- knex binds every Buffer with tedious `length: 'max'` (a string), and
-- tedious 20.3.3 then writes the PLP value without its terminator: 4002
-- (state 2 when the message ends at a chunk length, 4 inside chunk data).
-- An empty Buffer bound without a length declares max length 0: 8016, the
-- state names the type. Both roll back an open transaction. The emulator
-- used to drop the connection (knex/typeorm "socket hang up").
-- @step batch
SELECT 1 AS before_;
-- @step rpc
-- @param @b varbinary('max') = "beef"
SELECT @b AS b
-- @step batch
SELECT @@TRANCOUNT AS tc, 2 AS after_;
-- @step rpc
-- @param @a int = 5
-- @param @b varbinary('max') = "beef"
-- @param @c int = 7
SELECT @a AS a, @b AS b, @c AS c
-- @step rpc
-- @param @b varbinary = ""
SELECT @b AS b
-- @step rpc
-- @param @b varbinary('max') = ""
SELECT DATALENGTH(@b) AS b
-- @step rpc
-- @param @b varchar(0) = ""
SELECT @b AS b
-- @step rpc
-- @param @b nvarchar(0) = ""
SELECT @b AS b
-- @step rpc
-- @param @b binary(0) = ""
SELECT @b AS b
-- @step rpc
-- @param @a int = 1
-- @param @b varbinary(0) = ""
SELECT @b AS b
-- @step batch
BEGIN TRAN;
-- @step rpc
-- @param @b varbinary('max') = "beef"
SELECT @b AS b
-- @step batch
SELECT @@TRANCOUNT AS tc;
BEGIN TRAN;
-- @step rpc
-- @param @b varbinary = ""
SELECT @b AS b
-- @step batch
SELECT @@TRANCOUNT AS tc;
