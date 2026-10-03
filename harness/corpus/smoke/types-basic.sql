SELECT CAST(1 AS bit) AS b, CAST(2 AS tinyint) AS ti, CAST(3 AS smallint) AS si, CAST(4 AS bigint) AS bi,
  CAST(1.5 AS decimal(10,2)) AS d, CAST(2.5 AS float) AS f, CAST('abc' AS varchar(10)) AS vc,
  CAST(N'abc' AS nchar(5)) AS nc, CAST(0x0102 AS varbinary(4)) AS vb,
  CAST('2024-01-02T03:04:05.1234567' AS datetime2(7)) AS dt2,
  CAST('6F9619FF-8B86-D011-B42D-00C04FD430C8' AS uniqueidentifier) AS g
