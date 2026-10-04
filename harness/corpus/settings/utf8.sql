-- UTF-8 collations (…_SC_UTF8, …_BIN2_UTF8): varchar holds any Unicode
-- text stored as UTF-8; lengths, DATALENGTH, varbinary and hashes count
-- UTF-8 bytes; the wire carries UTF-8 (collation flag 0x40).
-- @step batch
SELECT CAST(N'aé€😀' AS varchar(20)) COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS relabel, CAST(N'aé€😀' COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(20)) AS conv, 'x' COLLATE Latin1_General_100_BIN2_UTF8 AS b2
-- @step batch
CREATE TABLE u (id int NOT NULL PRIMARY KEY, v varchar(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, c char(4) COLLATE Latin1_General_100_CI_AS_SC_UTF8, n nvarchar(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8);
INSERT u VALUES (1, N'aé€😀', N'é', N'é😀');
SELECT v, c, n, LEN(v) AS lv, DATALENGTH(v) AS dv, DATALENGTH(c) AS dc, LEN(n) AS ln, DATALENGTH(n) AS dn, CONVERT(varbinary(20), v) AS bv, CONVERT(varbinary(20), c) AS bc FROM u;
SELECT name, max_length, collation_name FROM sys.columns WHERE object_id = OBJECT_ID('u') ORDER BY column_id;
-- @step batch
INSERT u (id, v) VALUES (2, N'ééééééé')
-- @step batch
INSERT u (id, v) VALUES (3, N'ééééé'); SELECT v, DATALENGTH(v) AS dv FROM u WHERE id = 3
-- @step batch
SELECT CAST(N'ééééé' COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(5)) AS cut, DATALENGTH(CAST(N'ééééé' COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(5))) AS dl
-- @step batch
SELECT CAST(0xC3A9 AS varchar(10)) COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS from_bin_relabel, CONVERT(varchar(10), 0xC3A9) AS from_bin_default
-- @step batch
SELECT SUBSTRING(v, 2, 2) AS sub, LEFT(v, 3) AS l3, RIGHT(v, 1) AS r1, REVERSE(v) AS rev, UPPER(v) AS up, LOWER(c) AS lo, v + 'x' AS cat FROM u WHERE id = 1
-- @step batch
SELECT CASE WHEN v = N'AÉ€😀' THEN 1 ELSE 0 END AS eq_ci, CASE WHEN v LIKE 'a%' THEN 1 ELSE 0 END AS lk, CASE WHEN 'é' COLLATE Latin1_General_100_CI_AS_SC_UTF8 = 'e' THEN 1 ELSE 0 END AS accent FROM u WHERE id = 1
-- @step batch
SELECT CAST(v AS varchar(20)) COLLATE SQL_Latin1_General_CP1_CI_AS AS back_1252, CAST(v AS nvarchar(20)) AS to_n FROM u WHERE id = 1
-- @step batch
SELECT HASHBYTES('MD5', v) AS h, BINARY_CHECKSUM(v) AS bcs, ASCII(v) AS a, UNICODE(v) AS un FROM u WHERE id = 1
-- @step batch
SELECT v FROM u WHERE v = 'aé€😀' COLLATE Latin1_General_100_BIN2_UTF8 ORDER BY id
-- @step batch
SELECT 'x' COLLATE Latin1_General_100_CI_AS_UTF8 AS no_sc
-- @step batch
SELECT 'x' COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS a, 'x' COLLATE Latin1_General_100_CS_AS_SC_UTF8 AS b, 'x' COLLATE Latin1_General_100_CI_AI_SC_UTF8 AS c
-- @step rpc
-- @param @p nvarchar(20) = "zé😀"
SELECT CAST(@p COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(20)) AS v, DATALENGTH(CAST(@p COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(20))) AS dl
-- @step batch
ALTER DATABASE CURRENT COLLATE Latin1_General_100_CI_AS_SC_UTF8
-- @step batch
DECLARE @v varchar(10) = N'é😀'; SELECT 'é😀' AS lit, @v AS v, DATALENGTH(@v) AS dl, LEN('é😀') AS ln, DATALENGTH('é😀') AS dlit
-- @step batch
CREATE TABLE d (v varchar(10)); INSERT d VALUES (N'é😀'); SELECT v, DATALENGTH(v) AS dl FROM d; SELECT collation_name FROM sys.columns WHERE object_id = OBJECT_ID('d')
-- @step batch
ALTER DATABASE CURRENT COLLATE SQL_Latin1_General_CP1_CI_AS
