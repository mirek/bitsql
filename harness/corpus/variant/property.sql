-- SQL_VARIANT_PROPERTY for every base type: BaseType, Precision, Scale,
-- TotalBytes, Collation, MaxLength (result is itself sql_variant), unknown
-- properties, NULL and non-string arguments.
-- @step setup
CREATE TABLE dbo.p (id int NOT NULL PRIMARY KEY, v sql_variant NULL);
INSERT INTO dbo.p VALUES (1, CAST(CAST(1 AS bit) AS sql_variant)), (2, CAST(CAST(1 AS tinyint) AS sql_variant)),
  (3, CAST(CAST(1 AS smallint) AS sql_variant)), (4, CAST(1 AS sql_variant)), (5, CAST(CAST(1 AS bigint) AS sql_variant)),
  (6, CAST(CAST(1.5 AS decimal(10,2)) AS sql_variant)), (7, CAST(CAST(1.5 AS numeric(5,1)) AS sql_variant)),
  (8, CAST(CAST(1 AS money) AS sql_variant)), (9, CAST(CAST(1 AS smallmoney) AS sql_variant)),
  (10, CAST(CAST(1 AS float) AS sql_variant)), (11, CAST(CAST(1 AS real) AS sql_variant)),
  (12, CAST('abc' AS sql_variant)), (13, CAST(CAST('abc' AS char(10)) AS sql_variant)), (14, CAST(N'abc' AS sql_variant)),
  (15, CAST(CAST(N'abc' AS nchar(10)) AS sql_variant)), (16, CAST(0x0102 AS sql_variant)),
  (17, CAST(CAST(0x01 AS binary(5)) AS sql_variant)), (18, CAST(CAST('2024-01-01' AS date) AS sql_variant)),
  (19, CAST(CAST('01:02:03' AS time(3)) AS sql_variant)), (20, CAST(CAST('2024-01-01' AS datetime2(4)) AS sql_variant)),
  (21, CAST(CAST('2024-01-01' AS datetimeoffset(5)) AS sql_variant)), (22, CAST(CAST('2024-01-01' AS datetime) AS sql_variant)),
  (23, CAST(CAST('2024-01-01' AS smalldatetime) AS sql_variant)),
  (24, CAST(CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS sql_variant)), (25, NULL),
  (26, CAST('abc' COLLATE Latin1_General_100_CS_AS AS sql_variant)),
  (27, CAST(CAST(12345678901234567890 AS decimal(38,0)) AS sql_variant)), (28, CAST(CAST(1 AS decimal(19,0)) AS sql_variant)),
  (29, CAST(CAST(1 AS decimal(20,0)) AS sql_variant)), (30, CAST(1.5 AS sql_variant)),
  (31, CAST(CAST(1 AS decimal(5,2)) AS sql_variant)), (32, CAST(CAST('2024-01-01 01:02:03.45' AS datetime2(2)) AS sql_variant)),
  (33, CAST(CAST('2024-01-01' AS datetime2(7)) AS sql_variant)), (34, CAST(CAST(N'' AS nvarchar(3)) AS sql_variant)),
  (35, CAST(CAST(N'abc' AS nvarchar(4000)) AS sql_variant)), (36, CAST(CAST('abc' AS varchar(8000)) AS sql_variant)),
  (37, CAST(CAST(0x01 AS varbinary(8000)) AS sql_variant)), (38, CAST(CAST('01:02:03' AS time(0)) AS sql_variant)),
  (39, CAST(CAST('2024-01-01' AS datetime2(0)) AS sql_variant)), (40, CAST(CAST('2024-01-01' AS datetimeoffset(0)) AS sql_variant));
-- @step batch
SELECT id, SQL_VARIANT_PROPERTY(v, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(v, 'Precision') AS p,
       SQL_VARIANT_PROPERTY(v, 'Scale') AS s, SQL_VARIANT_PROPERTY(v, 'TotalBytes') AS tb,
       SQL_VARIANT_PROPERTY(v, 'Collation') AS c, SQL_VARIANT_PROPERTY(v, 'MaxLength') AS ml,
       DATALENGTH(v) AS dl, SQL_VARIANT_PROPERTY(v, 'bogus') AS bogus
FROM dbo.p ORDER BY id;
-- @step batch
SELECT SQL_VARIANT_PROPERTY(1, 'basetype') AS a, SQL_VARIANT_PROPERTY(N'x', 'BASETYPE') AS b,
       SQL_VARIANT_PROPERTY(NULL, 'BaseType') AS c, SQL_VARIANT_PROPERTY(1, NULL) AS d,
       SQL_VARIANT_PROPERTY(1, N'Precision') AS e, SQL_VARIANT_PROPERTY(1, ' BaseType') AS f,
       SQL_VARIANT_PROPERTY(1, 2) AS g, SQL_VARIANT_PROPERTY('x', 'Collation') AS h;
SELECT SQL_VARIANT_PROPERTY(SQL_VARIANT_PROPERTY(1, 'BaseType'), 'BaseType') AS bt_of_bt,
       SQL_VARIANT_PROPERTY(SQL_VARIANT_PROPERTY(1, 'BaseType'), 'MaxLength') AS ml_of_bt,
       SQL_VARIANT_PROPERTY(SQL_VARIANT_PROPERTY(1, 'Precision'), 'BaseType') AS bt_of_p,
       CAST(SQL_VARIANT_PROPERTY(1, 'Precision') AS varchar(10)) + 'x' AS p_text,
       CONVERT(int, SQL_VARIANT_PROPERTY(1, 'Precision')) AS p_int;
DECLARE @n nvarchar(20) = 'BaseType';
SELECT SQL_VARIANT_PROPERTY(1, @n) AS from_var;
-- @step batch
SELECT SQL_VARIANT_PROPERTY(CAST('x' AS varchar(max)), 'BaseType');
-- @step batch
SELECT SQL_VARIANT_PROPERTY(1);
