-- Native JSON construction storage through SQL value-carrying contexts.
-- @step batch
DECLARE @j json=N'{"a":1}'; DECLARE @copy json=@j;
SELECT @copy AS j,DATALENGTH(@copy) AS bytes,DATALENGTH(CAST(@copy AS json)) AS recast,DATALENGTH(CAST(NULL AS json)) AS null_bytes;
-- @step batch
CREATE TABLE jc(id int PRIMARY KEY,j json);
INSERT jc VALUES(1,N'{"a":1}'),(2,N'[1,2]'),(3,NULL);
SELECT id,j,DATALENGTH(j) AS bytes FROM jc ORDER BY id;
-- @step batch
UPDATE jc SET j=N'{"b":123456789012345678901234567890}' WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes FROM jc WHERE id=1;
-- @step batch
SELECT DATALENGTH(JSON_ARRAY(1,2 RETURNING JSON)) AS a,DATALENGTH(JSON_OBJECT('a':1 RETURNING JSON)) AS b;
-- @step batch
DECLARE @j json=N'{"a":1}'; SELECT DATALENGTH(JSON_ARRAY(@j)) AS a,DATALENGTH(JSON_OBJECT('b':@j)) AS b;
-- @step batch
SELECT DATALENGTH(JSON_ARRAYAGG(j)) AS a,DATALENGTH(JSON_OBJECTAGG(CAST(id AS varchar(10)):j)) AS b FROM jc;
-- @step batch
DECLARE @j json=N'{"a":[1,2],"b":{"c":3}}';
SELECT DATALENGTH(@j) AS original,DATALENGTH(JSON_QUERY(@j,'$')) AS root,DATALENGTH(JSON_QUERY(@j,'$.a')) AS a,DATALENGTH(JSON_QUERY(@j,'$.b')) AS b;
-- @step batch
DECLARE @j json=N'{"a":"abcdefgh","b":1}';
SET @j=JSON_MODIFY(@j,'$.a','x');
SELECT DATALENGTH(JSON_QUERY(@j,'$')) AS root,DATALENGTH(CAST(CAST(@j AS nvarchar(max)) AS json)) AS rebuilt;
-- @step batch
SELECT DATALENGTH(j) AS bytes FROM OPENJSON(N'{"j":{"a":1}}') WITH(j json AS JSON);
-- @step batch
SELECT DATALENGTH(substring_matches) AS bytes FROM REGEXP_MATCHES(N'abc',N'(a)(b)');
