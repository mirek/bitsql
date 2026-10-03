-- TM BEGIN inside a transaction nests; TM COMMIT without a transaction fails.
-- @step tm begin read_committed
-- @step tm begin read_committed
-- @step batch
SELECT @@TRANCOUNT AS tc;
-- @step tm commit
-- @step batch
SELECT @@TRANCOUNT AS tc;
-- @step tm commit
-- @step tm commit
-- @step tm rollback
