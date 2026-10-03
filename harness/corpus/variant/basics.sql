-- sql_variant values of every base type: COLMETADATA (SSVARIANT, max length
-- 8009), ROW bytes as tedious decodes them, NBCROW with NULL variants,
-- columns and variables of type sql_variant, DATALENGTH.
-- @step batch
SELECT CAST(CAST(1 AS bit) AS sql_variant) AS bit_, CAST(CAST(200 AS tinyint) AS sql_variant) AS tiny,
       CAST(CAST(-2 AS smallint) AS sql_variant) AS small, CAST(7 AS sql_variant) AS int_,
       CAST(CAST(-3 AS bigint) AS sql_variant) AS big, CAST(CAST(1.5 AS decimal(5,2)) AS sql_variant) AS dec5,
       CAST(CAST(12345678901234567890 AS decimal(38,0)) AS sql_variant) AS dec38,
       CAST(CAST(-1.5 AS numeric(5,2)) AS sql_variant) AS num, CAST(CAST(1.25 AS money) AS sql_variant) AS money_,
       CAST(CAST(1.5 AS smallmoney) AS sql_variant) AS smallmoney_, CAST(CAST(-2.5 AS float) AS sql_variant) AS float_,
       CAST(CAST(1.5 AS real) AS sql_variant) AS real_;
SELECT CAST('xy' AS sql_variant) AS vc, CAST(CAST('ab' AS char(4)) AS sql_variant) AS ch,
       CAST(N'abc' AS sql_variant) AS nvc, CAST(CAST(N'ab' AS nchar(5)) AS sql_variant) AS nch,
       CAST(CAST(N'abc' AS nvarchar(4000)) AS sql_variant) AS nvc4000,
       CAST(CAST('ab' AS varchar(4)) COLLATE Latin1_General_100_CS_AS AS sql_variant) AS vc_cs,
       CAST(0x0102 AS sql_variant) AS vb, CAST(CAST(0x01 AS binary(3)) AS sql_variant) AS bin,
       CAST(CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS sql_variant) AS guid;
SELECT CAST(CAST('2024-01-02' AS date) AS sql_variant) AS d, CAST(CAST('03:04:05.12' AS time(2)) AS sql_variant) AS t2,
       CAST(CAST('2024-01-02 03:04:05.1234567' AS datetime2(7)) AS sql_variant) AS dt27,
       CAST(CAST('2024-01-02 03:04:05.12 +01:30' AS datetimeoffset(2)) AS sql_variant) AS dto2,
       CAST(CAST('2024-01-02 03:04:05.123' AS datetime) AS sql_variant) AS dt,
       CAST(CAST('2024-01-02 03:04' AS smalldatetime) AS sql_variant) AS sdt,
       CONVERT(nvarchar(40), CAST(CAST('2024-01-02 03:04:05.1234567' AS datetime2(7)) AS sql_variant), 121) AS dt27_text,
       CONVERT(nvarchar(40), CAST(CAST('2024-01-02 03:04:05.12 +01:30' AS datetimeoffset(2)) AS sql_variant), 127) AS dto2_text;
SELECT CAST(NULL AS sql_variant) AS n1, CAST(1 AS sql_variant) AS one, CAST(NULL AS sql_variant) AS n2;
SELECT DATALENGTH(CAST(1 AS sql_variant)) AS dl_int, DATALENGTH(CAST(N'abc' AS sql_variant)) AS dl_nvc,
       DATALENGTH(CAST(1.5 AS sql_variant)) AS dl_num, DATALENGTH(CAST(NULL AS sql_variant)) AS dl_null,
       DATALENGTH(CAST(CAST(12345678901234567890 AS decimal(38,0)) AS sql_variant)) AS dl_dec38,
       DATALENGTH(CAST(12345678901234567890 AS decimal(38,0))) AS dl_plain_dec38,
       DATALENGTH(CAST(CAST(1 AS decimal(38,0)) AS sql_variant)) AS dl_dec38_small,
       DATALENGTH(CAST(CAST('2024-01-01' AS datetime2(2)) AS sql_variant)) AS dl_dt22,
       DATALENGTH(CAST(CAST(N'' AS nvarchar(3)) AS sql_variant)) AS dl_empty;
-- @step batch
CREATE TABLE dbo.v (id int NOT NULL PRIMARY KEY, v sql_variant NULL);
INSERT INTO dbo.v VALUES (1, 1);
INSERT INTO dbo.v VALUES (2, N'two');
INSERT INTO dbo.v VALUES (3, 3.5);
INSERT INTO dbo.v VALUES (4, NULL);
INSERT INTO dbo.v VALUES (5, CAST('2024-05-06' AS date));
SELECT id, v FROM dbo.v ORDER BY id;
SELECT id, SQL_VARIANT_PROPERTY(v, 'BaseType') AS bt FROM dbo.v ORDER BY id;
UPDATE dbo.v SET v = CAST(9 AS bigint) WHERE id = 1;
SELECT v, SQL_VARIANT_PROPERTY(v, 'BaseType') AS bt FROM dbo.v WHERE id = 1;
-- @step batch
DECLARE @v sql_variant;
SELECT @v AS unset;
SET @v = N'abc';
SELECT @v AS a, SQL_VARIANT_PROPERTY(@v, 'BaseType') AS bt;
SET @v = 1.5;
SELECT @v AS b, SQL_VARIANT_PROPERTY(@v, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(@v, 'Precision') AS p;
SELECT @v = 7;
SELECT @v AS c;
DECLARE @w sql_variant = CAST(CAST(1 AS sql_variant) AS sql_variant);
SELECT @w AS w, SQL_VARIANT_PROPERTY(@w, 'BaseType') AS bt;
-- @step rpc
-- @param @p int = 42
DECLARE @v sql_variant = @p;
SELECT @v AS v, SQL_VARIANT_PROPERTY(@v, 'BaseType') AS bt
