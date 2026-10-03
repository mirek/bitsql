-- STRING_SPLIT: value column type/length, ordinal argument, empty strings,
-- NULL input, multi-character separator error, APPLY.
-- @step batch
SELECT value FROM STRING_SPLIT('a,b,,c', ',');
SELECT value, ordinal FROM STRING_SPLIT(N'x y', ' ', 1);
SELECT * FROM STRING_SPLIT(NULL, ',');
SELECT COUNT(*) AS n FROM STRING_SPLIT('', ',');
DECLARE @s varchar(20) = '1;2;3';
SELECT CAST(value AS int) * 2 AS v FROM STRING_SPLIT(@s, ';') ORDER BY v DESC;
DECLARE @t TABLE (id int, tags nvarchar(50));
INSERT @t VALUES (1, N'red,blue'), (2, N'green');
SELECT t.id, s.value FROM @t t CROSS APPLY STRING_SPLIT(t.tags, ',') s ORDER BY t.id, s.value;
SELECT * FROM STRING_SPLIT('a,b', ',', 0);
-- @step batch
SELECT * FROM STRING_SPLIT('a,b', ',,');
-- @step batch
DECLARE @m varchar(max) = REPLICATE(CAST('ab,' AS varchar(max)), 3);
SELECT value FROM STRING_SPLIT(@m, ',');
