-- Surrogate normalization in regex replacements, flags, errors and tables.
-- @step batch
DECLARE @p nvarchar(10)=NCHAR(55296)+N'['; SELECT REGEXP_COUNT(N'x',@p) AS n;
-- @step batch
DECLARE @p nvarchar(10)=N'['+NCHAR(55296); SELECT REGEXP_COUNT(N'x',@p) AS n;
-- @step batch
SELECT REGEXP_COUNT(N'x',N'.',1,NCHAR(55296)) AS n;
-- @step batch
SELECT REGEXP_REPLACE(N'x',N'.',NCHAR(55296)) AS s;
-- @step batch
SELECT REGEXP_REPLACE(NCHAR(55296),N'z',N'x') AS s;
-- @step batch
SELECT REGEXP_REPLACE(NCHAR(55296),N'(\C)',N'\1') AS s;
-- @step batch
SELECT * FROM REGEXP_MATCHES(NCHAR(55296),N'.');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(NCHAR(55296),N'.');
-- @step batch
SELECT REGEXP_COUNT(NCHAR(55296)+NCHAR(55296),N'.') AS n,REGEXP_COUNT(NCHAR(55296)+NCHAR(56320),N'.') AS pair;
-- @step batch
SELECT REGEXP_COUNT(NCHAR(56320)+NCHAR(55296),N'.') AS n;
