-- OPENJSON (default schema, path, WITH schema incl. AS JSON, strict errors)
-- and STRING_SPLIT (with and without enable_ordinal), APPLY over them.
-- @step setup
CREATE TABLE tf (id int NOT NULL, j nvarchar(200) NULL, s varchar(50) NULL);
INSERT INTO tf VALUES (1, N'[1,2]', 'a,b'), (2, N'{"k":"v"}', 'c'), (3, NULL, NULL);
-- @step batch
SELECT [key], [value], [type] FROM OPENJSON(N'{"a":[1,{"b":2}],"c":"x"}', '$.a');
-- @step batch
SELECT * FROM OPENJSON(N'{"o":{"x":1,"y":[1,2]}}') WITH (o nvarchar(max) '$.o' AS JSON, x int '$.o.x', y nvarchar(max) '$.o.y' AS JSON, z varchar(3) 'lax $.nope');
-- @step batch
SELECT * FROM OPENJSON(N'[{"a":"12"},{"a":"x"}]') WITH (a int);
-- @step batch
SELECT * FROM OPENJSON(N'{"a":1}', 'strict $.b');
-- @step batch
SELECT * FROM OPENJSON(N'not json');
-- @step batch
SELECT tf.id, o.[key], o.[value] FROM tf CROSS APPLY OPENJSON(tf.j) o ORDER BY tf.id, o.[key];
-- @step batch
SELECT tf.id, o.[value] FROM tf OUTER APPLY OPENJSON(tf.j) o ORDER BY tf.id;
-- @step batch
SELECT value FROM STRING_SPLIT('a,b,,c', ',');
-- @step batch
SELECT value, ordinal FROM STRING_SPLIT(N'x;y;z', ';', 1);
-- @step batch
SELECT * FROM STRING_SPLIT('a b', ' ', 0);
-- @step batch
SELECT tf.id, p.value FROM tf CROSS APPLY STRING_SPLIT(tf.s, ',') p ORDER BY tf.id, p.value;
-- @step batch
SELECT value FROM STRING_SPLIT('a,b', ',,');
-- @step batch
SELECT value FROM STRING_SPLIT(NULL, ',');
