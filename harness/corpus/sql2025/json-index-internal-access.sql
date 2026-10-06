-- @step batch
CREATE TABLE t(id int CONSTRAINT pk PRIMARY KEY,j json);
CREATE JSON INDEX ix ON t(j);
-- @step batch
DECLARE @name nvarchar(128)=(SELECT name FROM sys.internal_tables WHERE parent_id=OBJECT_ID(N't'));
BEGIN TRY
  EXEC(N'SELECT * FROM sys.'+@name);
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS error_number,REPLACE(ERROR_MESSAGE(),@name,N'<internal>') AS message;
END CATCH;
SELECT CASE WHEN OBJECT_ID(N'sys.'+name)=object_id THEN 1 ELSE 0 END AS resolves_id,CASE WHEN OBJECT_NAME(object_id)=name THEN 1 ELSE 0 END AS resolves_name FROM sys.internal_tables WHERE parent_id=OBJECT_ID(N't');
