-- SQL Server 2025 feature audit: regex.
-- @step batch
SELECT REGEXP_REPLACE('abc123', '[0-9]+', 'X') AS replaced, REGEXP_COUNT('a1b2', '[0-9]') AS matches;
