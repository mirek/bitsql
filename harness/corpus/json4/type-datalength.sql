-- DATALENGTH of a json value is the size of SQL Server's internal binary
-- json format (43 bytes for {"a":1}), not of its text: not emulated
-- (bitsql raises an Emulator error; this case keeps the gap visible).
DECLARE @j json = N'{"a":1}'; SELECT DATALENGTH(@j) AS d, DATALENGTH(CAST(N'[1,2,3]' AS json)) AS e
