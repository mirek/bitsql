-- sys.parameters of procedures and functions: table-valued (READONLY,
-- system_type_id 243), alias-typed and system-typed parameters, the scalar
-- function's return value (parameter_id 0, empty name).
-- @step setup
CREATE TYPE dbo.IdList AS TABLE (id int NOT NULL PRIMARY KEY);
CREATE TYPE dbo.Email FROM nvarchar(256) NOT NULL;
-- @step setup
CREATE FUNCTION dbo.f_count (@ids dbo.IdList READONLY, @e dbo.Email = N'x') RETURNS decimal(10,2) AS BEGIN RETURN (SELECT COUNT(*) FROM @ids) END;
-- @step setup
CREATE FUNCTION dbo.f_rows (@ids dbo.IdList READONLY) RETURNS TABLE AS RETURN SELECT id * 10 AS x FROM @ids;
-- @step setup
CREATE PROCEDURE dbo.p @a int = 5, @b nvarchar(10) OUTPUT, @c dbo.Email, @d datetime2(3) AS SELECT 1;
-- @step batch
SELECT OBJECT_NAME(object_id) AS o, name, parameter_id, system_type_id, user_type_id, max_length, precision, scale, is_output, is_cursor_ref, has_default_value, is_xml_document, default_value, xml_collection_id, is_readonly, is_nullable, encryption_type, encryption_type_desc, encryption_algorithm_name, column_encryption_key_id, column_encryption_key_database_name, vector_dimensions, vector_base_type, vector_base_type_desc FROM sys.parameters ORDER BY o, parameter_id;
