-- SQL Server 2025 feature audit: fuzzy.
-- @step batch
SELECT EDIT_DISTANCE('kitten', 'sitting') AS distance, JARO_WINKLER_SIMILARITY('MARTHA', 'MARHTA') AS similarity;
