-- FOR JSON formats sql_variant values as their base type.
-- @step batch
SELECT CAST(1 AS sql_variant) AS a, CAST(N'x' AS sql_variant) AS b, CAST(1.5 AS sql_variant) AS c,
       CAST(CAST('2024-01-02' AS date) AS sql_variant) AS d, CAST(0x01 AS sql_variant) AS e,
       CAST(CAST(1 AS bit) AS sql_variant) AS f, CAST(CAST(2.5 AS float) AS sql_variant) AS g,
       CAST(NULL AS sql_variant) AS h, CAST(CAST('2024-01-02 03:04:05.5' AS datetime2(1)) AS sql_variant) AS i,
       CAST(CAST(3 AS money) AS sql_variant) AS j
FOR JSON PATH, INCLUDE_NULL_VALUES;
SELECT CAST(3 AS money) AS a, CAST(3 AS smallmoney) AS b, CAST(CAST(3 AS smallmoney) AS sql_variant) AS c,
       CAST(CAST(1.5 AS decimal(5,2)) AS sql_variant) AS d, CAST(CAST(1.5 AS real) AS sql_variant) AS e,
       CAST(1.5 AS real) AS f, CAST(CAST('2024-01-02 03:04:05.123' AS datetime) AS sql_variant) AS g,
       CAST(CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS sql_variant) AS h,
       CAST(CAST('ab' AS char(4)) AS sql_variant) AS i
FOR JSON PATH;
