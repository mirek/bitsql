-- sp_who for the current session (spid masked) and for an unknown login
-- (15007).
-- @step batch
-- @mask sets/0/rows/*/0
DECLARE @me sysname = CAST(@@SPID AS sysname);
EXEC sp_who @me;
-- @step batch
EXEC sp_who 'nobody';
