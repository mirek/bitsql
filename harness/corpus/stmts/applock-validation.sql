-- sp_releaseapplock / sp_getapplock / APPLOCK_* validation order when
-- several arguments are wrong, principal names (case, trailing spaces) and
-- an xp_userlock error caught by TRY.
-- @step batch
EXEC sp_releaseapplock NULL
-- @step batch
EXEC sp_releaseapplock N'x', 'Transaction', 'nobody'
-- @step batch
EXEC sp_releaseapplock N'x', 'Transaction', NULL
-- @step batch
EXEC sp_getapplock NULL, 'Shared', 'Session', 0, NULL
-- @step batch
EXEC sp_getapplock N'x', 'Shared', 'Session', -2, NULL
-- @step batch
EXEC sp_getapplock N'x', 'SharedIntentExclusive', 'Session'
-- @step batch
DECLARE @rc int; EXEC @rc = sp_getapplock N'x', 'Shared', 'Session', 0, 'db_datareader '; SELECT @rc AS rc, APPLOCK_MODE('db_datareader', 'x', 'Session') AS m; EXEC sp_releaseapplock N'x', 'Session', 'DB_DATAREADER'
-- @step batch
SELECT APPLOCK_TEST('nobody', NULL, NULL, 'Bogus') AS t
-- @step batch
DECLARE @v nvarchar(10); SELECT APPLOCK_TEST(@v, @v, @v, 'Bogus') AS t
-- @step batch
DECLARE @v nvarchar(10); SELECT APPLOCK_MODE('public', @v, 'Bogus') AS m
-- @step batch
SELECT APPLOCK_MODE('public', 'x', 'Bogus') AS m, APPLOCK_MODE('nobody', 'x', 'Session') AS n
-- @step batch
SELECT APPLOCK_TEST('public', 'x', 'Exclusive', NULL) AS t
-- @step batch
BEGIN TRY EXEC sp_getapplock NULL, 'Shared', 'Session' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p, ERROR_LINE() AS l END CATCH
