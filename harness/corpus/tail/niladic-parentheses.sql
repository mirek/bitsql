-- Niladic functions (CURRENT_TIMESTAMP, USER, SESSION_USER, SYSTEM_USER,
-- CURRENT_USER) take no parentheses: 102 near the token after '('.
-- @step batch
SELECT CURRENT_TIMESTAMP()
-- @step batch
SELECT CURRENT_TIMESTAMP(1)
-- @step batch
SELECT CURRENT_TIMESTAMP (  )
-- @step batch
SELECT USER()
-- @step batch
SELECT SESSION_USER()
-- @step batch
SELECT SYSTEM_USER()
-- @step batch
SELECT CURRENT_USER()
-- @step batch
SELECT CURRENT_TIMESTAMP(1, 2)
