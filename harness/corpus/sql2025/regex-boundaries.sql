-- Regex pattern, argument and flag probes.
-- @step batch
SELECT REGEXP_COUNT('abc123', '[') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', 'a{') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', 'a{2,1}') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '*') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '\q') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '(?=a)') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '(?<=a)') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '(a)\1') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '[z-a]') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '(?:a)') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '(?i)a') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', 'a*?') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', 'a{1001}') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '[[:digit:]]') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '\p{L}') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc123', '\b') AS n;
-- @step batch
SELECT REGEXP_SUBSTR(123, 'a') AS s;
-- @step batch
SELECT REGEXP_SUBSTR(0x6162, 'a') AS s;
-- @step batch
SELECT REGEXP_SUBSTR(N'ab', 'a') AS s;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('ab' AS varchar(max)), 'a') AS s;
-- @step batch
SELECT REGEXP_SUBSTR(CAST('ab' AS text), 'a') AS s;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, 'ci') AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, 'ic') AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, 'I') AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, '') AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, NULL) AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, 'ii') AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, 'iscm') AS n;
-- @step batch
SELECT REGEXP_COUNT('A', 'a', 1, 'xxz') AS n;
-- @step batch
SELECT REGEXP_COUNT('abc','a',4) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc','a',-1) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc','a',NULL) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc','a',1.5) AS n;
-- @step batch
SELECT REGEXP_COUNT('abc','a',CAST(1 AS bigint)) AS n;
-- @step batch
SELECT REGEXP_REPLACE('abc','b') AS r;
-- @step batch
SELECT REGEXP_REPLACE('aba','a','X',1,2) AS r;
-- @step batch
SELECT REGEXP_SUBSTR('abc','(.)',1,1,'c',2) AS s;
-- @step batch
SELECT REGEXP_INSTR('abc','b',1,1,1) AS pos;
-- @step batch
SELECT REGEXP_COUNT('abc','a',1,'c',1);
-- @step batch
SELECT * FROM REGEXP_SPLIT_TO_TABLE('abc','');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc','');
