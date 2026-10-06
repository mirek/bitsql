-- SQL Server 2025 feature audit: current-date.
-- @step batch
SELECT SQL_VARIANT_PROPERTY(CURRENT_DATE, 'BaseType') AS type, CASE WHEN CURRENT_DATE = CAST(GETDATE() AS date) THEN 1 ELSE 0 END AS same_day;
