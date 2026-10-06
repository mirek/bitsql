-- Fuzzy argument types, arity and bigint cutoff boundaries.
-- @step setup
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
SELECT EDIT_DISTANCE(CAST(NULL AS varchar(max)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE(CAST(NULL AS int),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS char(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nchar(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE(0x61,'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE(CAST(1 AS sql_variant),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE();
-- @step batch
SELECT EDIT_DISTANCE('a','b','c','d');
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY(CAST(NULL AS varchar(max)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY(CAST(NULL AS int),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY(CAST('a' AS char(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY(CAST('a' AS nchar(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY(0x61,'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY(CAST(1 AS sql_variant),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY();
-- @step batch
SELECT EDIT_DISTANCE_SIMILARITY('a','b','c','d');
-- @step batch
SELECT JARO_WINKLER_DISTANCE(CAST(NULL AS varchar(max)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_DISTANCE(CAST(NULL AS int),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_DISTANCE(CAST('a' AS char(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_DISTANCE(CAST('a' AS nchar(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_DISTANCE(0x61,'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_DISTANCE(CAST(1 AS sql_variant),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_DISTANCE();
-- @step batch
SELECT JARO_WINKLER_DISTANCE('a','b','c','d');
-- @step batch
SELECT JARO_WINKLER_SIMILARITY(CAST(NULL AS varchar(max)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_SIMILARITY(CAST(NULL AS int),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_SIMILARITY(CAST('a' AS char(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_SIMILARITY(CAST('a' AS nchar(10)),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_SIMILARITY(0x61,'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_SIMILARITY(CAST(1 AS sql_variant),'abc' COLLATE Latin1_General_100_CI_AS) AS v;
-- @step batch
SELECT JARO_WINKLER_SIMILARITY();
-- @step batch
SELECT JARO_WINKLER_SIMILARITY('a','b','c','d');
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(1 AS bit)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(1 AS tinyint)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(1 AS smallint)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(1 AS float)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(1 AS money)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(2147483648 AS bigint)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(9223372036854775807 AS bigint)) AS v;
-- @step batch
SELECT EDIT_DISTANCE('abc' COLLATE Latin1_General_100_CI_AS,'def',CAST(-9223372036854775808 AS bigint)) AS v;
