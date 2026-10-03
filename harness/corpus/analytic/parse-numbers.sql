-- PARSE / TRY_PARSE to numeric types under en-US (default) and invariant
-- ('iv'): .NET NumberStyles.Number for integer and decimal targets
-- (thousands, trailing sign, zero fractions), Float for float/real
-- (exponent, no thousands), Currency for money (symbol, parentheses).
-- @step batch
SELECT PARSE('123' AS int) a, PARSE(' 123 ' AS int) b, PARSE('-123' AS int) c, PARSE('+5' AS int) d, PARSE('1,234' AS int) e, PARSE('1,234' AS int USING 'en-US') f;
-- @step batch
SELECT TRY_PARSE('1.5' AS int) a, TRY_PARSE('1e3' AS int) b, TRY_PARSE('2147483648' AS int) c, TRY_PARSE('' AS int) d, TRY_PARSE('$5' AS int) e, TRY_PARSE('0x10' AS int) f, TRY_PARSE('5-' AS int) g, TRY_PARSE('1.0' AS int) h, TRY_PARSE('12,34,5' AS int) i, TRY_PARSE(',1' AS int) j;
-- @step batch
SELECT TRY_PARSE('1,,2' AS int) a, TRY_PARSE('1,' AS int) b, TRY_PARSE('1.' AS int) c, TRY_PARSE('.' AS int) d, TRY_PARSE('-' AS int) e, TRY_PARSE('+-5' AS int) f, TRY_PARSE('5+' AS int) g, TRY_PARSE('1.00000' AS int) h, TRY_PARSE('1.5,0' AS int) i, TRY_PARSE('-5-' AS int) j, TRY_PARSE('1,234.' AS int) k, TRY_PARSE(CHAR(9)+'5'+CHAR(10) AS int) l;
-- @step batch
SELECT TRY_PARSE('  1 234 ' AS int) a, TRY_PARSE('1_000' AS int) b, TRY_PARSE(N'５' AS int) d, TRY_PARSE('00012' AS int) e, TRY_PARSE('-0' AS int) f, TRY_PARSE(' - 5' AS int) g, TRY_PARSE('5 -' AS int) h, TRY_PARSE('(5)' AS int) i;
-- @step batch
SELECT TRY_PARSE('255' AS tinyint) b, TRY_PARSE('256' AS tinyint) c, TRY_PARSE('-1' AS tinyint) d, TRY_PARSE('9223372036854775807' AS bigint) e, TRY_PARSE('9223372036854775808' AS bigint) f, TRY_PARSE('-32768' AS smallint) g, TRY_PARSE('32768' AS smallint) h, TRY_PARSE('-2147483648' AS int) i, TRY_PARSE('1E5' AS bigint) j;
-- @step batch
SELECT TRY_PARSE('1.5' AS decimal(10,2)) a, TRY_PARSE('1,234.567' AS decimal(10,2)) b, TRY_PARSE('1e3' AS decimal(10,2)) c, TRY_PARSE('$1.25' AS decimal(10,2)) d, TRY_PARSE('-1.235' AS decimal(10,2)) e, TRY_PARSE('1.225' AS decimal(10,2)) f, TRY_PARSE('123456789012' AS decimal(10,2)) g, TRY_PARSE('(1.5)' AS decimal(10,2)) h, TRY_PARSE('.5' AS decimal(10,2)) i, TRY_PARSE('5.' AS numeric(10,2)) j;
-- @step batch
SELECT TRY_PARSE('99999999.995' AS decimal(10,2)) a, TRY_PARSE('99999999.994' AS decimal(10,2)) b, CAST(TRY_PARSE('0.000000000000000000000000000001' AS decimal(38,30)) AS varchar(50)) c, CAST(TRY_PARSE('123456789012345678901234567890' AS decimal(38,0)) AS varchar(50)) d, TRY_PARSE('-0.001' AS decimal(5,2)) f, TRY_PARSE('5' AS numeric(5,1)) g;
-- @step batch
SELECT TRY_PARSE('$1,234.56' AS money) a, TRY_PARSE('1.23456' AS money) b, TRY_PARSE('(1.5)' AS money) c, TRY_PARSE('-$1.5' AS money) d, TRY_PARSE('$-1.5' AS money) e, TRY_PARSE('1e2' AS money) f, TRY_PARSE(N'€5' AS money) g, TRY_PARSE('1.5' AS smallmoney) h;
-- @step batch
SELECT TRY_PARSE('1.5$' AS money) a, TRY_PARSE('$ 1.5' AS money) b, TRY_PARSE('($1.5)' AS money) c, TRY_PARSE('$(1.5)' AS money) d, TRY_PARSE('1.5-' AS money) e, TRY_PARSE('-(1.5)' AS money) f, TRY_PARSE('1,234,567.12345' AS money) g, CAST(TRY_PARSE('922337203685477.5807' AS money) AS varchar(30)) h, TRY_PARSE('922337203685477.5808' AS money) i, TRY_PARSE('214748.3647' AS smallmoney) j, TRY_PARSE('214748.36475' AS smallmoney) k;
-- @step batch
SELECT TRY_PARSE('1.5e3' AS float) a, TRY_PARSE('1,234.5' AS float) b, TRY_PARSE('$1' AS float) c, TRY_PARSE('(1)' AS float) d, TRY_PARSE('NaN' AS float) e, TRY_PARSE('Infinity' AS float) f, TRY_PARSE('1e400' AS float) g, TRY_PARSE('.5E-2' AS real) h, TRY_PARSE('5-' AS float) i, TRY_PARSE('1e' AS float) j;
-- @step batch
SELECT TRY_PARSE('1e-400' AS float) a, TRY_PARSE('-1.5E+3' AS float) b, TRY_PARSE('1.e2' AS float) c, TRY_PARSE('.e2' AS float) d, TRY_PARSE('3.4e39' AS real) e, TRY_PARSE('1e-50' AS real) f, TRY_PARSE(' 1.5 ' AS float) g, TRY_PARSE('+.5' AS float) h, TRY_PARSE('0.1' AS float) i, TRY_PARSE('0.1' AS real) j;
-- @step batch
SELECT TRY_PARSE('5' AS int USING 'iv') a, TRY_PARSE('1,234.5' AS decimal(10,2) USING 'iv') b, TRY_PARSE(N'¤1.5' AS money USING 'iv') c, TRY_PARSE('$1.5' AS money USING 'iv') d, TRY_PARSE('5' AS int USING 'EN-us') e, TRY_PARSE('5' AS int USING 'en') f, TRY_PARSE('5' AS int USING 'en_US') g;
-- @step batch
DECLARE @s varchar(10) = '42', @n nvarchar(10) = NULL, @c nvarchar(10) = N'en-US';
SELECT PARSE(@s AS int) a, TRY_PARSE(@s AS decimal(5,1)) b, PARSE(@n AS int) c, TRY_PARSE(@s AS int USING @c) d;
-- @step batch
SELECT v, TRY_PARSE(v AS int) i, TRY_PARSE(v AS decimal(9,3)) d, TRY_PARSE(v AS money) m, TRY_PARSE(v AS float) f FROM (VALUES ('1'), ('-2.5'), ('3,000'), ('4e1'), ('x'), (NULL)) t(v);
