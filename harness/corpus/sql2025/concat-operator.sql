-- SQL Server 2025 feature audit: concat-operator.
-- @step batch
SELECT 'a' || 'b' AS joined, 'a' || CAST(NULL AS varchar(3)) AS null_joined;
