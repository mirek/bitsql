-- SQL Server 2025 fuzzy matching with database-scoped preview enabled.
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
SELECT EDIT_DISTANCE('kitten', 'sitting') AS distance, EDIT_DISTANCE_SIMILARITY('kitten', 'sitting') AS similarity;
-- @step batch
SELECT JARO_WINKLER_DISTANCE('MARTHA', 'MARHTA') AS distance, JARO_WINKLER_SIMILARITY('MARTHA', 'MARHTA') AS similarity;
-- @step batch
SELECT EDIT_DISTANCE('kitten' COLLATE Latin1_General_100_CI_AS, 'sitting') AS distance, EDIT_DISTANCE_SIMILARITY('kitten' COLLATE Latin1_General_100_CI_AS, 'sitting') AS similarity;
-- @step batch
SELECT JARO_WINKLER_DISTANCE('MARTHA' COLLATE Latin1_General_100_CI_AS, 'MARHTA') AS distance, JARO_WINKLER_SIMILARITY('MARTHA' COLLATE Latin1_General_100_CI_AS, 'MARHTA') AS similarity;
