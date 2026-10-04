-- TypeORM reads its migrations table as `"<db>".."migrations"`: a
-- three-part name with an empty schema part means the default schema.
-- @step setup
CREATE TABLE migrations (id int NOT NULL, name varchar(255) NOT NULL);
INSERT INTO migrations VALUES (1, 'Init1');
-- @step batch
DECLARE @db sysname = DB_NAME();
EXEC (N'SELECT * FROM [' + @db + N']..[migrations]');
EXEC (N'SELECT * FROM "' + @db + N'".."migrations" "migrations" ORDER BY "id" DESC');
EXEC (N'INSERT INTO [' + @db + N']..migrations (id, name) VALUES (2, ''Two'')');
SELECT id, name FROM migrations ORDER BY id;
