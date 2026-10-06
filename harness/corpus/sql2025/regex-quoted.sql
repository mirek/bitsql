-- Quoted literal quantification and negated classes.
-- @step batch
SELECT REGEXP_SUBSTR(N'abb', N'\Qab\E+',1,1,'i') AS s, REGEXP_COUNT(N'abb',N'\Qab\E+',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'abbb', N'\Qab\E{2}',1,1,'i') AS s, REGEXP_COUNT(N'abbb',N'\Qab\E{2}',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'aaa', N'a\Q\E+',1,1,'i') AS s, REGEXP_COUNT(N'aaa',N'a\Q\E+',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'abc', N'\Q\E+',1,1,'i') AS s, REGEXP_COUNT(N'abc',N'\Q\E+',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'abc', N'[[:^digit:]]',1,1,'i') AS s, REGEXP_COUNT(N'abc',N'[[:^digit:]]',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'abc', N'[\p{L}]',1,1,'i') AS s, REGEXP_COUNT(N'abc',N'[\p{L}]',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'aA1', N'\P{Lu}',1,1,'i') AS s, REGEXP_COUNT(N'aA1',N'\P{Lu}',1,'i') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(N'aA1', N'[^\p{Lu}]',1,1,'i') AS s, REGEXP_COUNT(N'aA1',N'[^\p{Lu}]',1,'i') AS n;
