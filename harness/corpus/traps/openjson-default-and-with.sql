-- Trap: OPENJSON default schema returns key/value/type; WITH casts.
SELECT [key], [value], [type] FROM OPENJSON(N'{"s":"x","n":1.5,"b":true,"z":null,"a":[1,2],"o":{"k":1}}');
SELECT * FROM OPENJSON(N'[{"id":1,"name":"a","price":"1.239"},{"id":"2","name":null}]')
  WITH (id int '$.id', name nvarchar(10) '$.name', price decimal(5,2) '$.price', missing int '$.nope');
