-- RETURNING json (the json data type) is not modelled by bitsql.
SELECT JSON_OBJECT('a':1 ABSENT ON NULL RETURNING json) a;
