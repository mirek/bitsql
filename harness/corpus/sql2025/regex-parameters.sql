-- Regex per-function numeric controls and typed NULL validation.
-- @step batch
SELECT REGEXP_COUNT('abc','a',-1,'c') AS v;
-- @step batch
SELECT REGEXP_COUNT('abc','a',0,'c') AS v;
-- @step batch
SELECT REGEXP_COUNT('abc','a',NULL,'c') AS v;
-- @step batch
SELECT REGEXP_COUNT('abc','a',CAST(1 AS bit),'c') AS v;
-- @step batch
SELECT REGEXP_COUNT(NULL,'a',1,'c') AS v;
-- @step batch
SELECT REGEXP_COUNT(CAST(NULL AS int),'a',1,'c') AS v;
-- @step batch
SELECT REGEXP_COUNT('abc',NULL,1,'c') AS v;
-- @step batch
SELECT REGEXP_COUNT('abc',CAST(NULL AS int),1,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',-1,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',0,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',NULL,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',CAST(1 AS bit),0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',1,-1,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',1,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',1,NULL,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc','a','x',1,CAST(1 AS bit),'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE(NULL,'a','x',1,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE(CAST(NULL AS int),'a','x',1,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc',NULL,'x',1,0,'c') AS v;
-- @step batch
SELECT REGEXP_REPLACE('abc',CAST(NULL AS int),'x',1,0,'c') AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',-1,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',0,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',NULL,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',CAST(1 AS bit),1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,-1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,NULL,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,CAST(1 AS bit),'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,1,'c',-1) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,1,'c',NULL) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc','a',1,1,'c',CAST(1 AS bit)) AS v;
-- @step batch
SELECT REGEXP_SUBSTR(NULL,'a',1,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR(CAST(NULL AS int),'a',1,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc',NULL,1,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_SUBSTR('abc',CAST(NULL AS int),1,1,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',-1,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',0,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',NULL,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',CAST(1 AS bit),1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,-1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,0,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,NULL,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,CAST(1 AS bit),0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,-1,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,NULL,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,CAST(1 AS bit),'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,0,'c',-1) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,0,'c',NULL) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc','a',1,1,0,'c',CAST(1 AS bit)) AS v;
-- @step batch
SELECT REGEXP_INSTR(NULL,'a',1,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR(CAST(NULL AS int),'a',1,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc',NULL,1,1,0,'c',0) AS v;
-- @step batch
SELECT REGEXP_INSTR('abc',CAST(NULL AS int),1,1,0,'c',0) AS v;
