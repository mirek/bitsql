-- Regex Unicode positions, collation independence and boundary semantics.
-- @step batch
SELECT REGEXP_COUNT(N'a😀b','.') AS n, REGEXP_INSTR(N'a😀b','b') AS p, REGEXP_SUBSTR(N'a😀b','.',1,2) AS s;
-- @step batch
SELECT REGEXP_COUNT(N'😀','.') AS n, REGEXP_COUNT(N'😀','\C') AS bytes;
-- @step batch
SELECT REGEXP_INSTR(N'é😀b','b') AS p, REGEXP_SUBSTR(N'é😀b','.',2,1) AS s;
-- @step batch
SELECT * FROM REGEXP_MATCHES(N'é😀b',N'(😀)(b)');
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE(N'a😀b','');
-- @step batch
SELECT REGEXP_COUNT('A' COLLATE Latin1_General_100_CI_AI,'a') AS case_sensitive, REGEXP_COUNT(N'é' COLLATE Latin1_General_100_CI_AI,'e') AS accent_sensitive;
-- @step batch
SELECT REGEXP_COUNT('a'+CHAR(10)+'b','^b',1,'m') AS n, REGEXP_COUNT('a'+CHAR(10)+'b','.',1,'s') AS dotall;
-- @step batch
SELECT REGEXP_COUNT('a'+CHAR(10),'a$') AS n, REGEXP_COUNT('a'+CHAR(10),'a$',1,'m') AS m;
-- @step batch
SELECT REGEXP_COUNT('aaa','a*?') AS n, REGEXP_REPLACE('aaa','a*?','X') AS r;
-- @step batch
SELECT REGEXP_REPLACE('abc','(.)','\0-\1') AS r;
-- @step batch
SELECT REGEXP_REPLACE('abc','(.)','$1') AS r;
-- @step batch
SELECT REGEXP_SUBSTR(N'a😀b','.',3) AS s;
