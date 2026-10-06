-- SQL Server 2025 Base64 padding and malformed-input error precedence.
-- @step batch
SELECT BASE64_DECODE('A') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAAA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAAAA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('A=') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA=') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAA=') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAAA=') AS decoded;
-- @step batch
SELECT BASE64_DECODE('=') AS decoded;
-- @step batch
SELECT BASE64_DECODE('==') AS decoded;
-- @step batch
SELECT BASE64_DECODE('===') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA==') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAA==') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAAA==') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA===') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA=A') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AAA=A') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA==!') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA=!=') AS decoded;
-- @step batch
SELECT BASE64_DECODE('A!') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA==A') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA==AA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA==AAA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA==AAAA') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA= A') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AA= =') AS decoded;
-- @step batch
SELECT BASE64_DECODE('++__') AS decoded;
-- @step batch
SELECT BASE64_DECODE('--//') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AB') AS decoded;
-- @step batch
SELECT BASE64_DECODE('ABC') AS decoded;
-- @step batch
SELECT BASE64_DECODE('AB==') AS decoded;
-- @step batch
SELECT BASE64_DECODE('ABC=') AS decoded;
