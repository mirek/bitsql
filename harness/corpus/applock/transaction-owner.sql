-- Transaction-owned app locks need a transaction and end with it.
-- @step batch
DECLARE @r int;
EXEC @r = sp_getapplock @Resource = N'job', @LockMode = 'Shared';
SELECT @r AS no_tx;
-- @step batch
DECLARE @r int;
BEGIN TRAN;
EXEC @r = sp_getapplock @Resource = N'job', @LockMode = 'Update';
SELECT @r AS got, APPLOCK_MODE('public', N'job', 'Transaction') AS mode;
COMMIT;
SELECT APPLOCK_MODE('public', N'job', 'Transaction') AS after_commit;
-- @step batch
DECLARE @r int;
EXEC @r = sp_getapplock @Resource = N'job', @LockMode = 'Bogus', @LockOwner = 'Session';
SELECT @r AS bad_mode;
