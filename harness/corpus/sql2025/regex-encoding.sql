-- BOM content is data; partial-byte replacements are decoded only at the end.
-- @step batch
SELECT REGEXP_COUNT(NCHAR(65279)+N'x',N'.') AS n,REGEXP_SUBSTR(NCHAR(65279)+N'x',N'.') AS s,REGEXP_INSTR(NCHAR(65279)+N'x',N'x') AS i;
-- @step batch
SELECT REGEXP_REPLACE(NCHAR(65279)+N'x',N'x',N'y') AS s;
-- @step batch
SELECT REGEXP_SUBSTR(N'x'+NCHAR(65279),N'.',1,2) AS s;
-- @step batch
SELECT * FROM REGEXP_MATCHES(NCHAR(65279)+N'x',N'.');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(NCHAR(65279)+N'x',N'x');
-- @step batch
SELECT REGEXP_REPLACE(N'π',N'(\C)',N'\1',1,1) AS s,REGEXP_REPLACE(N'π',N'(\C)',N'\1',1,2) AS t;
-- @step batch
SELECT REGEXP_REPLACE(N'π',N'\C',N'X',1,1) AS s,REGEXP_REPLACE(N'π',N'\C',N'X',1,2) AS t;
-- @step batch
SELECT REGEXP_REPLACE(NCHAR(55296),N'.',N'x',1,2) AS unchanged;
-- @step batch
SELECT REGEXP_REPLACE(NCHAR(55296)+N'x',N'x',N'y') AS s;
