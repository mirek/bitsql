-- A second session times out (-1) with @LockTimeout = 0, and waits (1)
-- for the release otherwise; APPLOCK_TEST sees the conflict.
-- @step batch
DECLARE @r int;
EXEC @r = sp_getapplock @Resource = N'migrate', @LockMode = 'Exclusive', @LockOwner = 'Session';
SELECT @r AS got;
-- @step batch conn=2
DECLARE @r int;
EXEC @r = sp_getapplock @Resource = N'migrate', @LockMode = 'Shared', @LockOwner = 'Session', @LockTimeout = 0;
SELECT @r AS timed_out, APPLOCK_TEST('public', N'migrate', 'Shared', 'Session') AS test_other;
-- @step batch conn=2 async
DECLARE @r int;
EXEC @r = sp_getapplock @Resource = N'migrate', @LockMode = 'Shared', @LockOwner = 'Session';
SELECT @r AS waited;
-- @step batch
DECLARE @r int;
EXEC @r = sp_releaseapplock @Resource = N'migrate', @LockOwner = 'Session';
SELECT @r AS released;
-- @step await conn=2
-- @step batch conn=2
SELECT APPLOCK_MODE('public', N'migrate', 'Session') AS mode2;
