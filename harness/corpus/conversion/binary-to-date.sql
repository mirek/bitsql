-- Binary converts explicitly to date, time, datetime2 and datetimeoffset
-- (241 on a bad image, not 529); implicitly it is 257. The values are an
-- internal image the emulator does not decode (Emulator error).
-- @step batch
SELECT CAST(0x01 AS date);
-- @step batch
SELECT CAST(0x5B950A AS date) AS d, CAST(CAST('2020-01-02' AS date) AS varbinary(10)) AS b;
-- @step batch
SELECT CAST(0x01 AS time);
-- @step batch
SELECT CAST(0x01 AS datetime2);
-- @step batch
SELECT CAST(0x01 AS datetimeoffset);
-- @step batch
DECLARE @d date = 0x01;
