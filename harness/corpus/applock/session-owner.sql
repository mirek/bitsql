-- sp_getapplock / sp_releaseapplock with a Session owner; APPLOCK_MODE and
-- APPLOCK_TEST; releasing a lock that is not held.
-- @step batch
DECLARE @r int;
EXEC @r = sp_getapplock @Resource = N'migrate', @LockMode = 'Exclusive', @LockOwner = 'Session';
SELECT @r AS got, APPLOCK_MODE('public', N'migrate', 'Session') AS mode, APPLOCK_TEST('public', N'migrate', 'Shared', 'Session') AS test_self;
EXEC @r = sp_getapplock @Resource = N'migrate', @LockMode = 'Exclusive', @LockOwner = 'Session';
SELECT @r AS again;
EXEC @r = sp_releaseapplock @Resource = N'migrate', @LockOwner = 'Session';
SELECT @r AS rel1, APPLOCK_MODE('public', N'migrate', 'Session') AS mode1;
EXEC @r = sp_releaseapplock @Resource = N'migrate', @LockOwner = 'Session';
SELECT @r AS rel2, APPLOCK_MODE('public', N'migrate', 'Session') AS mode2;
-- @step batch
DECLARE @r int;
EXEC @r = sp_releaseapplock @Resource = N'migrate', @LockOwner = 'Session';
SELECT @r AS rel3;
