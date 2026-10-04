-- USE inside EXEC / sp_executesql switches the database only for that
-- scope: no ENVCHANGE and no 5701 message, the caller's database is back
-- afterwards (ORM migration scripts run USE through dynamic SQL).
-- @step batch
EXEC (N'USE tempdb; SELECT DB_NAME() AS inside');
SELECT DB_NAME() AS after_;
-- @step rpc
EXEC (N'USE tempdb; SELECT DB_NAME() AS inside');
SELECT DB_NAME() AS after_
-- @step batch
EXEC sp_executesql N'USE tempdb; SELECT DB_NAME() AS inside';
SELECT DB_NAME() AS after_;
-- @step batch
EXEC (N'USE nope_db_x');
SELECT DB_NAME() AS after_;
