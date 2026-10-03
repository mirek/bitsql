-- sp_set_session_context / SESSION_CONTEXT, CONTEXT_INFO.
-- @step batch
EXEC sp_set_session_context @key = N'user_id', @value = 42;
EXEC sp_set_session_context N'tenant', N'acme', 1;
SELECT SESSION_CONTEXT(N'user_id') AS uid, SESSION_CONTEXT(N'tenant') AS tenant, SESSION_CONTEXT(N'missing') AS missing;
SELECT CAST(SESSION_CONTEXT(N'user_id') AS int) + 1 AS next_uid;
-- @step batch
EXEC sp_set_session_context N'tenant', N'other';
