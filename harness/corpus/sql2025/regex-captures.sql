-- Ordered alternatives, repeated and optional capture groups.
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab12cd34', '([a-z]+)([0-9]+)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('aaa', '(a|aa)+');
-- @step batch
SELECT * FROM REGEXP_MATCHES('aaa', '(aa|a)+');
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab', '(a*)(b*)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('a', '(a?)*');
-- @step batch
SELECT * FROM REGEXP_MATCHES('aa', '(a?)*');
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab', '(a)?(b)?');
-- @step batch
SELECT * FROM REGEXP_MATCHES('b', '(a)?(b)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc', '((ab)|a)(c)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab', '(a|ab)(b?)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('ab', '(ab|a)(b?)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abbb', '(a)(b+?)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abb', '(a(b)*)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('aaa', '((a)*)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc', 'a.*?c');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc', 'a.*c');
-- @step batch
SELECT * FROM REGEXP_MATCHES('aaa', '(a{1,2})(a*)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('aaa', '(a{1,2}?)(a*)');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc', '(?i:a)(?-i:b)c');
-- @step batch
SELECT * FROM REGEXP_MATCHES('abc', 'a|');
