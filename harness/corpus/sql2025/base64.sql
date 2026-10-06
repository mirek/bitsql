-- SQL Server 2025 feature audit: base64.
-- @step batch
SELECT BASE64_ENCODE(0x48656C6C6F) AS encoded, BASE64_DECODE('SGVsbG8=') AS decoded;
-- @step batch
SELECT BASE64_ENCODE(0xFBEFFF) AS standard, BASE64_ENCODE(0xFBEFFF, 1) AS url_safe, BASE64_DECODE('-_8') AS url_decoded;
-- @step batch
SELECT BASE64_ENCODE(0x) AS empty_encoded, BASE64_DECODE('') AS empty_decoded, BASE64_ENCODE(CAST(NULL AS varbinary(12))) AS null_encoded, BASE64_DECODE(CAST(NULL AS varchar(12))) AS null_decoded;
-- @step batch
DECLARE @b varbinary(10) = 0x01020304, @s varchar(10) = 'AQIDBA==';
SELECT BASE64_ENCODE(@b) AS encoded, BASE64_DECODE(@s) AS decoded, BASE64_ENCODE(CAST(@b AS varbinary(max))) AS max_encoded, BASE64_DECODE(CAST(@s AS varchar(max))) AS max_decoded;
-- @step batch
SELECT BASE64_ENCODE(0x01) AS one, BASE64_ENCODE(0x0102) AS two, BASE64_ENCODE(0x010203) AS three, BASE64_ENCODE(0x01, 1) AS url_one;
-- @step batch
SELECT BASE64_DECODE('AQ') AS no_padding, BASE64_DECODE('AQ==') AS padding, BASE64_DECODE(' AQ== ') AS spaces;
-- @step batch
SELECT BASE64_DECODE('!');
-- @step batch
SELECT BASE64_DECODE('A');
-- @step batch
SELECT BASE64_DECODE('AQ===');
-- @step batch
SELECT BASE64_ENCODE('abc');
-- @step batch
SELECT BASE64_DECODE(N'AQ==');
-- @step batch
SELECT BASE64_ENCODE(NULL), BASE64_DECODE(NULL);
-- @step batch
SELECT BASE64_ENCODE(0x01, NULL);
-- @step batch
SELECT BASE64_ENCODE(0x01, 2);
-- @step batch
SELECT BASE64_ENCODE();
-- @step batch
SELECT BASE64_DECODE('AQ==', 1);
-- @step batch
DECLARE @b varbinary(6001) = 0x01, @c binary(3) = 0x01, @s char(8) = 'AQ==';
SELECT BASE64_ENCODE(@b) AS large_capacity, BASE64_ENCODE(@c) AS fixed_binary, BASE64_DECODE(@s) AS fixed_char;
-- @step batch
SELECT BASE64_ENCODE(0x01, 'true');
-- @step batch
SELECT BASE64_ENCODE(0x01, 'bad');
-- @step batch
SELECT BASE64_DECODE('AQ='), BASE64_DECODE('AB=='), BASE64_DECODE('AAB=');
-- @step batch
SELECT BASE64_DECODE('A=');
-- @step batch
SELECT BASE64_DECODE('=');
-- @step batch
SELECT BASE64_DECODE('AQ==AA');
-- @step batch
SELECT BASE64_DECODE('AQ' + CHAR(9) + CHAR(10) + CHAR(13) + '==');
-- @step batch
SELECT BASE64_DECODE('AQ' + CHAR(11) + '==');
-- @step batch
SELECT BASE64_ENCODE(0x01, CAST(0.5 AS decimal(3,1))) AS decimal_flag, BASE64_ENCODE(0x01, CAST(0.5 AS float)) AS float_flag, BASE64_ENCODE(0x01, CAST(-1 AS bigint)) AS bigint_flag;
-- @step batch
DECLARE @b varbinary(6000) = 0x01;
SELECT BASE64_ENCODE(@b) AS threshold;
-- @step batch
SELECT BASE64_DECODE('AQ= =') AS spaced_padding, BASE64_DECODE('AQI=') AS two_bytes;
-- @step batch
SELECT BASE64_DECODE('AAAA=');
-- @step batch
SELECT BASE64_DECODE('AQ!===');
-- @step batch
SELECT BASE64_ENCODE(0x01, CAST(0.5 AS float));
-- @step batch
SELECT BASE64_ENCODE(0x01, CAST(-1 AS bigint)) AS bigint_flag, BASE64_ENCODE(0x01, CAST(1 AS bit)) AS bit_flag;
-- @step batch
DECLARE @v sql_variant = CAST(0x01 AS varbinary(1)); SELECT BASE64_ENCODE(@v);
-- @step batch
SELECT BASE64_ENCODE(CAST(0x01 AS image));
-- @step batch
SELECT BASE64_DECODE(CAST('AQ==' AS text));
-- @step batch
SELECT BASE64_ENCODE(0x01, CAST(1 AS bit)) AS bit_flag;
-- @step batch
SELECT BASE64_ENCODE(0x01, CAST(1 AS smallint)) AS smallint_flag;
-- @step batch
SELECT BASE64_ENCODE(0x01, CAST(1 AS tinyint)) AS tinyint_flag;
-- @step batch
DECLARE @b varbinary(8000) = CAST(REPLICATE('x', 6001) AS varbinary(8000));
SELECT DATALENGTH(BASE64_ENCODE(@b)) AS encoded_bytes, DATALENGTH(BASE64_DECODE(BASE64_ENCODE(@b))) AS decoded_bytes;
