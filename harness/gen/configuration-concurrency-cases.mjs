// Ordered operations on two connections; oracle mutations require a disposable instance.
export const configurationConcurrencyCases = [
  {
    "who": "b",
    "sql": "SET LOCK_TIMEOUT 100;"
  },
  {
    "who": "a",
    "sql": "BEGIN TRAN;"
  },
  {
    "who": "a",
    "sql": "EXEC sp_configure 'external rest endpoint enabled',1;"
  },
  {
    "who": "b",
    "sql": "SELECT value,value_in_use FROM sys.configurations WHERE name='external rest endpoint enabled';"
  },
  {
    "who": "b",
    "sql": "SELECT value,value_in_use FROM sys.configurations WITH(NOLOCK) WHERE name='external rest endpoint enabled';"
  },
  {
    "who": "b",
    "sql": "SELECT value,value_in_use FROM sys.configurations WHERE name='allow updates';"
  },
  {
    "who": "b",
    "sql": "EXEC sp_configure 'external rest endpoint enabled';"
  },
  {
    "who": "a",
    "sql": "ROLLBACK;"
  },
  {
    "who": "b",
    "sql": "SELECT value,value_in_use FROM sys.configurations WHERE name='external rest endpoint enabled';"
  },
  {
    "who": "a",
    "sql": "BEGIN TRAN; EXEC sp_configure 'external rest endpoint enabled',1; COMMIT;"
  },
  {
    "who": "b",
    "sql": "SELECT value,value_in_use FROM sys.configurations WHERE name='external rest endpoint enabled';"
  },
  {
    "who": "b",
    "sql": "RECONFIGURE;"
  },
  {
    "who": "a",
    "sql": "SELECT value,value_in_use FROM sys.configurations WHERE name='external rest endpoint enabled';"
  },
  {
    "who": "a",
    "sql": "BEGIN TRAN; EXEC sp_configure 'external rest endpoint enabled',0;"
  },
  {
    "who": "b",
    "sql": "RECONFIGURE;"
  },
  {
    "who": "a",
    "sql": "ROLLBACK;"
  },
  {
    "who": "b",
    "sql": "SELECT value,value_in_use FROM sys.configurations WHERE name='external rest endpoint enabled';"
  },
  {
    "who": "b",
    "sql": "EXEC sp_configure 'external rest endpoint enabled',0; RECONFIGURE;"
  },
  {
    "who": "a",
    "sql": "CREATE FUNCTION dbo.configuration_value() RETURNS int AS BEGIN DECLARE @v int; SELECT @v=CONVERT(int,value) FROM sys.configurations WHERE name='external rest endpoint enabled'; RETURN @v; END;"
  },
  {
    "who": "a",
    "sql": "BEGIN TRAN; EXEC sp_configure 'external rest endpoint enabled',1;"
  },
  {
    "who": "b",
    "sql": "SELECT dbo.configuration_value() AS configured;"
  },
  {
    "who": "b",
    "sql": "BEGIN TRY SELECT value FROM sys.configurations WHERE name='external rest endpoint enabled'; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n,ERROR_LINE() AS line,ERROR_PROCEDURE() AS proc_name; END CATCH;"
  },
  {
    "who": "b",
    "sql": "BEGIN TRY EXEC sp_configure 'external rest endpoint enabled'; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n,ERROR_LINE() AS line,ERROR_PROCEDURE() AS proc_name; END CATCH;"
  },
  {
    "who": "b",
    "sql": "SELECT TRY_CAST((SELECT value FROM sys.configurations WHERE name='external rest endpoint enabled') AS int) AS configured;"
  },
  {
    "who": "a",
    "sql": "ROLLBACK;"
  },
  {
    "who": "b",
    "sql": "SELECT dbo.configuration_value() AS configured;"
  },
  {
    "who": "a",
    "sql": "DROP FUNCTION dbo.configuration_value;"
  }
]
