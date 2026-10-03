-- sys.dm_exec_sessions / requests / connections for this session, and a
-- request blocked by it (filtered to this session: the oracle is shared).
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY, v int);
INSERT t VALUES (1, 1);
-- @step batch
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRAN;
UPDATE t SET v = 2 WHERE id = 1;
SELECT status, login_name, is_user_process, transaction_isolation_level, open_transaction_count, lock_timeout, deadlock_priority, date_first, text_size, language, date_format, quoted_identifier, ansi_nulls, ansi_warnings, ansi_padding, concat_null_yields_null, arithabort, ansi_defaults
FROM sys.dm_exec_sessions WHERE session_id = @@SPID;
SELECT status, command, transaction_isolation_level, open_transaction_count, blocking_session_id, wait_type FROM sys.dm_exec_requests WHERE session_id = @@SPID;
SELECT net_transport, protocol_type, protocol_version, auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID;
-- @step batch conn=2 async
UPDATE t SET v = 3 WHERE id = 1;
-- @step batch conn=3 async
BEGIN TRAN; UPDATE t SET v = 4 WHERE id = 1; COMMIT;
-- @step batch
SELECT status, command, wait_type, open_transaction_count FROM sys.dm_exec_requests WHERE blocking_session_id <> 0 AND session_id <> @@SPID ORDER BY open_transaction_count;
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
-- @step await conn=2
-- @step await conn=3
