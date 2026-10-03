-- TM BEGIN with an isolation level sets the session's level.
-- @step tm begin serializable
-- @step batch
SELECT CASE transaction_isolation_level WHEN 1 THEN 'RU' WHEN 2 THEN 'RC' WHEN 3 THEN 'RR' WHEN 4 THEN 'SER' WHEN 5 THEN 'SNAP' END AS lvl FROM sys.dm_exec_sessions WHERE session_id = @@SPID;
-- @step tm commit
-- @step batch
SELECT CASE transaction_isolation_level WHEN 1 THEN 'RU' WHEN 2 THEN 'RC' WHEN 3 THEN 'RR' WHEN 4 THEN 'SER' WHEN 5 THEN 'SNAP' END AS lvl FROM sys.dm_exec_sessions WHERE session_id = @@SPID;
