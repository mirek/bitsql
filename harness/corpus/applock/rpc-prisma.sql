-- Prisma Migrate's lock call shape over RPC.
-- @step rpc
EXEC sp_getapplock @Resource = 'prisma_migrate', @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 10000;
-- @step rpc
SELECT APPLOCK_MODE('public', 'prisma_migrate', 'Session') AS mode;
-- @step rpc
EXEC sp_releaseapplock @Resource = 'prisma_migrate', @LockOwner = 'Session';
