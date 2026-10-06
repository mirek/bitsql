-- Lone UTF-16 surrogate input and patterns.
-- @step batch
SELECT REGEXP_SUBSTR(NCHAR(55296),N'.') AS v;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(55296),N'.') AS v;
-- @step batch
SELECT REGEXP_COUNT(N'x',NCHAR(55296)) AS v;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(55296),NCHAR(55296)) AS v;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(55296),N'\C') AS v;
-- @step batch
SELECT REGEXP_SUBSTR(NCHAR(56320),N'.') AS v;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(56320),N'.') AS v;
-- @step batch
SELECT REGEXP_COUNT(N'x',NCHAR(56320)) AS v;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(56320),NCHAR(56320)) AS v;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(56320),N'\C') AS v;
