-- Unicode properties, RE2 quote syntax and simple case folding.
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{L}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\pL') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\P{L}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{^L}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\P{^L}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{Greek}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{Latin}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{Any}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{ASCII}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{Cn}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{Letter}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{latin}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{Unknown}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{NoSuch}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p{}') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\p') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\Q(a+b)\E') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'aΑ1é😀(a+b)abc', N'\Qabc') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'é', N'É',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'σ', N'ς',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'Σ', N'ς',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'ſ', N's',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'K', N'k',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'İ', N'i',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'ı', N'I',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'ß', N'ẞ',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'ß', N'ss',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'ﬀ', N'ff',1,'i') AS n;
-- @step batch
SELECT REGEXP_COUNT(N'𐐀', N'𐐨',1,'i') AS n;
