-- Oracle graph edges for the bounded cosine fixture; investigative, not a passing emulator case.
-- @step setup
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=ON;
CREATE TABLE t(id int CONSTRAINT PK_t PRIMARY KEY,v vector(3));
WITH nums AS (SELECT TOP(20) ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS n FROM sys.all_columns)
INSERT t SELECT n,CONCAT('[',((n*47)%997)/997.0,',',((n*71)%991)/991.0,',',((n*113)%983)/983.0,']') FROM nums;
-- @step batch
CREATE VECTOR INDEX vi ON t(v) WITH(METRIC='cosine');
-- @step batch
DECLARE @dump TABLE(parent_object nvarchar(4000),object_name nvarchar(4000),field nvarchar(4000),value nvarchar(4000));
DECLARE @nodes TABLE(src_id int,neighbors varbinary(max));
DECLARE @file int,@page int,@sql nvarchar(max);
DECLARE pages CURSOR LOCAL FAST_FORWARD FOR
SELECT p.allocated_page_file_id,p.allocated_page_page_id
FROM sys.internal_tables t CROSS APPLY sys.dm_db_database_page_allocations(DB_ID(),t.object_id,NULL,NULL,'DETAILED') p
WHERE t.parent_id=OBJECT_ID('t') AND t.internal_type=31 AND p.page_type=1 AND p.is_allocated=1;
OPEN pages;
FETCH NEXT FROM pages INTO @file,@page;
WHILE @@FETCH_STATUS=0
BEGIN
 DELETE @dump;
 SET @sql=N'DBCC PAGE ('+QUOTENAME(DB_NAME(),'''')+N','+CONVERT(nvarchar(20),@file)+N','+CONVERT(nvarchar(20),@page)+N',3) WITH TABLERESULTS,NO_INFOMSGS;';
 INSERT @dump EXEC(@sql);
 INSERT @nodes
 SELECT CONVERT(int,s.value),CONVERT(varbinary(max),e.hex,2)
 FROM @dump s
 OUTER APPLY(
  SELECT STRING_AGG(CONVERT(varchar(max),CASE WHEN d.value LIKE N'0x%' THEN SUBSTRING(d.value,3,4000)
   ELSE REPLACE(LEFT(x.payload,CHARINDEX(N'  ',x.payload)-1),N' ',N'') END),'') WITHIN GROUP(ORDER BY d.value COLLATE Latin1_General_100_BIN2) AS hex
  FROM @dump d CROSS APPLY(SELECT LTRIM(SUBSTRING(d.value,CHARINDEX(N':',d.value)+1,4000)) AS payload)x
  WHERE d.parent_object=s.parent_object AND d.object_name LIKE N'pruned_dest_ids%'
 )e
 WHERE s.field=N'src_id';
 FETCH NEXT FROM pages INTO @file,@page;
END;
CLOSE pages;
DEALLOCATE pages;
SELECT src_id,neighbors FROM @nodes ORDER BY src_id;
