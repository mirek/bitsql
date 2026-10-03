-- Identity and permission functions as the sa login sees them.
-- @step batch
SELECT USER_NAME() AS un, USER_ID() AS uid, SUSER_NAME() AS sn, SUSER_SNAME() AS ssn, SUSER_ID() AS sid, CURRENT_USER AS cu, SESSION_USER AS su, SYSTEM_USER AS sysu, USER AS u, ORIGINAL_LOGIN() AS ol;
SELECT IS_SRVROLEMEMBER('sysadmin') AS sa, IS_MEMBER('db_owner') AS dbo, IS_ROLEMEMBER('db_owner') AS rm, HAS_DBACCESS(DB_NAME()) AS acc, DATABASE_PRINCIPAL_ID() AS dp, USER_NAME(1) AS u1, SUSER_SID() AS ssid;
SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE TABLE') AS can_create, PERMISSIONS() AS perms;
