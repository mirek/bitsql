-- Result metadata of string and constant expressions (binder rules in
-- docs/reference/result-metadata.md): folded arithmetic keeps its
-- nullability, an untyped NULL concatenates as varchar(1), fixed + fixed is
-- fixed, NULLIF types an integer literal by value and folds, ISNULL is NOT
-- NULL when a constant argument folds to a value, a folded CASE keeps a
-- same-charset branch and turns nullable on a truncating conversion,
-- JSON_QUERY is nvarchar(4000) unless its input is max.
SELECT 1+1 AS a, 2*3 AS b, N'a'+N'b' AS c, 1.5*2 AS d, 1e0+1 AS e, 'a'+NULL AS f, NULL+'a' AS g, 1+NULL AS h, -1 AS i, -(1) AS j, 0x01+0x02 AS k, 'a'+'b'+'c' AS l;
SELECT CAST('a' AS CHAR(6000))+CAST('b' AS CHAR(6000)) AS a, CAST('a' AS NCHAR(3000))+CAST('b' AS NCHAR(3000)) AS b, CAST('a' AS CHAR(2))+'xy' AS c, 'xy'+CAST('a' AS CHAR(2)) AS d, CAST('a' AS CHAR(2))+NULL AS e, NULL+CAST('a' AS NCHAR(2)) AS f, NULL+NULL AS g, N'a'+NULL AS h, NULL+N'abc' AS i;
SELECT NULLIF(1,1) AS a, NULLIF(1000,1000) AS b, NULLIF(100000,100000) AS c, NULLIF(1,2) AS d, NULLIF(300,1) AS e, NULLIF(1.5,1.5) AS f, NULLIF('a','a') AS g, NULLIF(N'abc',N'abc') AS h, NULLIF(CAST(1 AS bigint),1) AS i, NULLIF(1,CAST(1 AS bigint)) AS j, NULLIF(-1,-1) AS k;
SELECT NULLIF(255,0) AS a, NULLIF(256,0) AS b, NULLIF(32767,0) AS c, NULLIF(32768,0) AS d, NULLIF(-128,0) AS e, NULLIF(0,0) AS f, NULLIF((1),0) AS g, NULLIF(1+1,0) AS h, NULLIF(-255,0) AS i, NULLIF(-32768,0) AS j, NULLIF(-32769,0) AS k, NULLIF(2147483648,0) AS l, NULLIF(1,NULL) AS m, NULLIF(-1,0) AS n, NULLIF(-0,0) AS o;
DECLARE @x int = 1;
SELECT NULLIF(@x,1) AS a, NULLIF(1,@x) AS b, NULLIF(2,@x) AS c;
SELECT CASE WHEN 1=2 THEN NULL ELSE 1 END AS a, CASE WHEN 1=1 THEN NULL ELSE 1 END AS b, IIF(1=1,NULL,1) AS c, COALESCE(NULL,1) AS d, ISNULL(1,2) AS e, ISNULL(NULL,300) AS f, CASE WHEN 1=1 THEN 1 END AS g;
SELECT IIF(1=1, CAST('a' AS char(2)), 'abc') AS a, CASE WHEN 1=1 THEN N'a' ELSE CAST(N'b' AS nchar(5)) END AS b, IIF(1=1, 'abc', CAST('a' AS char(5))) AS c, IIF(1=1, CHAR(65), 'abc') AS d, IIF(1=1, 'ab', CHAR(65)) AS e;
SELECT CASE WHEN 1=1 THEN REPLICATE(CAST('a' AS varchar(max)), 1) ELSE N'x' END AS a, CASE WHEN 1=1 THEN 'abc' ELSE N'x' END AS b, IIF(1=1, NULL, N'x') AS c, COALESCE(NULL, 'abc') AS d;
SELECT ISNULL(CAST(NULL AS int), 1+1) AS a, ISNULL(CAST(NULL AS varchar(3)), LEFT('abc',2)) AS b, ISNULL(CAST(NULL AS varchar(3)), CHAR(NULL)) AS c, ISNULL(CAST(NULL AS int), CAST(1 AS int)) AS d, COALESCE(CAST(NULL AS varchar(3)), CHAR(65)) AS f;
DECLARE @j nvarchar(max) = N'{}', @k nvarchar(10) = N'{}', @v varchar(20) = '{}';
SELECT JSON_QUERY(@j) AS a, JSON_QUERY(@k) AS b, JSON_QUERY(@v) AS c, JSON_QUERY(@k, '$') AS d, JSON_QUERY(N'{"a":[1]}', '$.a') AS e;
SELECT CASE WHEN LEFT(N'abc', 1) = N'a' THEN 1 WHEN NOT (LEFT(N'abc', 1) = N'a') THEN 0 ELSE NULL END AS folded_left,
       CASE WHEN LEN('abc') = 3 THEN 1 WHEN NOT (LEN('abc') = 3) THEN 0 ELSE NULL END AS folded_len,
       CASE WHEN SPACE(2) = '' THEN 1 WHEN NOT (SPACE(2) = '') THEN 0 ELSE NULL END AS folded_space;
