-- Trap: JSON paths are lax by default (NULL) while strict raises an error.
SELECT JSON_VALUE(N'{"a":1,"o":{"x":2}}', '$.b') AS lax_missing,
       JSON_VALUE(N'{"a":1,"o":{"x":2}}', '$.o') AS lax_object,
       JSON_QUERY(N'{"a":1,"o":{"x":2}}', '$.a') AS lax_query_scalar,
       JSON_VALUE(N'{"a":1,"o":{"x":2}}', 'strict $.a') AS strict_ok;
-- @step batch
SELECT JSON_VALUE(N'{"a":1}', 'strict $.b') AS strict_missing;
-- @step batch
SELECT JSON_VALUE(N'{"a":1,"o":{"x":2}}', 'strict $.o') AS strict_object;
