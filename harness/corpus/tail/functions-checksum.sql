-- CHECKSUM of decimal/numeric (|value| as a 38-digit integer folded over its
-- 32-bit words) and of Unicode text under the version-0 Windows tables
-- (primary sort key words folded with rotl3; case and accents ignored).
-- @step batch
SELECT v, CHECKSUM(v) AS c, BINARY_CHECKSUM(v) AS b FROM (VALUES (CAST(0 AS decimal(38,6))), (1), (-1), (0.000001), (123456.789), (99999999999999999999999999999999.999999), (-0.5), (7.25)) t(v) ORDER BY v
-- @step batch
SELECT CHECKSUM(CAST(12345678901234567890123456789012345678 AS decimal(38,0))) AS a, CHECKSUM(CAST(0.00000000000000000000000000000000000001 AS decimal(38,38))) AS b, CHECKSUM(CAST(1 AS numeric(1,0))) AS c, CHECKSUM(CAST(42.4200 AS decimal(9,4)), 1) AS d
-- @step batch
SELECT CHECKSUM(N'Hello, World! 123') AS a, CHECKSUM(N'HELLO, WORLD! 123') AS b, CHECKSUM(N'Straße') AS c, CHECKSUM(N'Strasse') AS d, CHECKSUM(N'naïve café') AS e, CHECKSUM(N'Ωμέγα кириллица') AS f, CHECKSUM(N'日本語テキスト') AS g, CHECKSUM(N'abcdefghijklmnopqrstuvwxyz') AS h, CHECKSUM(N'a' + NCHAR(0x3000)) AS i, CHECKSUM(N'a' + NCHAR(0x3000) + N'b') AS j, CHECKSUM(N'co-op') AS k, CHECKSUM(N'æble') AS l
-- @step batch
SELECT CHECKSUM(CAST('Hello, World! 123' AS varchar(30)) COLLATE Latin1_General_CI_AS) AS a, CHECKSUM(CAST('Größe' AS varchar(30)) COLLATE Latin1_General_CS_AS) AS b, CHECKSUM(N'Größe' COLLATE Latin1_General_CI_AI) AS c, CHECKSUM(N'xyz' COLLATE SQL_Latin1_General_CP1_CS_AS) AS d, CHECKSUM(N'one', N'two', 3) AS e
