-- Regex start offsets, anchors and replacement escape processing.
-- @step batch
SELECT REGEXP_COUNT('abc','^b',2) AS c, REGEXP_SUBSTR('abc','^b',2) AS s, REGEXP_INSTR('abc','^b',2) AS i, REGEXP_REPLACE('abc','^b','X',2) AS r;
-- @step batch
SELECT REGEXP_COUNT('abc','$',4) AS c, REGEXP_SUBSTR('abc','$',4) AS s, REGEXP_INSTR('abc','$',4) AS i, REGEXP_REPLACE('abc','$','X',4) AS r;
-- @step batch
SELECT REGEXP_REPLACE('ab','(.)','\\1') AS literal, REGEXP_REPLACE('ab','(.)','\0') AS zero, REGEXP_REPLACE('ab','(.)','\9') AS missing;
-- @step batch
SELECT REGEXP_REPLACE('abc','a',NULL) AS replacement_null;
