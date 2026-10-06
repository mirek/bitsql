-- Collation expansion and combining mark behavior for fuzzy algorithms.
-- @step setup
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
SELECT a,b,
 EDIT_DISTANCE(a COLLATE Latin1_General_100_CI_AS,b) AS ed,
 EDIT_DISTANCE_SIMILARITY(a COLLATE Latin1_General_100_CI_AS,b) AS es,
 JARO_WINKLER_DISTANCE(a COLLATE Latin1_General_100_CI_AS,b) AS jd,
 JARO_WINKLER_SIMILARITY(a COLLATE Latin1_General_100_CI_AS,b) AS js
FROM (VALUES
 (N'ßx',N'ssy'),(N'æx',N'aey'),(N'ß',N'sx'),
 (N'é',N'e'+NCHAR(769)),(N'éx',N'ey'),
 (N'e'+NCHAR(769),N'e'),(N'e'+NCHAR(769),N'x'),
 (N'a'+NCHAR(8203)+N'b',N'ac'),(NCHAR(8203),N''),
 (N'Ａx',N'Ay'),(N'😀x',N'😃y'),
 (N'abc',N'acb'),(N'CA',N'ABC')
) p(a,b);
-- @step batch
SELECT EDIT_DISTANCE(NULL,'a') AS ed,
 JARO_WINKLER_DISTANCE(NULL,'a') AS jd;
-- @step batch
SELECT EDIT_DISTANCE('a','a') AS ed;
