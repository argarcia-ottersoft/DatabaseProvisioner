USE
[msdb];
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DatabaseProvisioner_Cleanup')
BEGIN
EXEC sp_delete_job @job_name = N'DatabaseProvisioner_Cleanup', @delete_unused_schedule = 1;
END
GO

EXEC sp_add_job
    @job_name = N'DatabaseProvisioner_Cleanup',
    @description = N'Drops provisioned agent databases not accessed in the last 1 day. Handles orphaned tracking rows and untracked databases.';
GO

EXEC sp_add_jobstep
    @job_name = N'DatabaseProvisioner_Cleanup',
    @step_name = N'Drop stale databases and clean up tracking',
    @subsystem = N'TSQL',
    @database_name = N'master',
    @command = N'
DECLARE @cutoff DATETIME2 = DATEADD(DAY, -1, SYSUTCDATETIME());
DECLARE @sql NVARCHAR(MAX) = N'''';
DECLARE @dropped INT = 0;

-- 1. Drop tracked databases that have not been accessed within the retention period.
--    Snapshots must be dropped before their parent database.
SELECT @sql = @sql +
    N''IF DB_ID(N'''''' + FullDatabaseName + N''_dbss'''') IS NOT NULL DROP DATABASE ['' + FullDatabaseName + N''_dbss];'' + CHAR(13) +
    N''IF DB_ID(N'''''' + FullDatabaseName + N'''''') IS NOT NULL DROP DATABASE ['' + FullDatabaseName + N''];'' + CHAR(13)
FROM master.dbo.ProvisionedDatabases
WHERE LastAccessedUtc < @cutoff;

IF @sql <> N''''
BEGIN
    EXEC sp_executesql @sql;
    SET @sql = N'''';
END

SELECT @dropped = COUNT(*) FROM master.dbo.ProvisionedDatabases WHERE LastAccessedUtc < @cutoff;

DELETE FROM master.dbo.ProvisionedDatabases
WHERE LastAccessedUtc < @cutoff;

-- 2. Clean up orphaned tracking rows where the database was already dropped manually.
DELETE FROM master.dbo.ProvisionedDatabases
WHERE DB_ID(FullDatabaseName) IS NULL;

-- 3. Drop untracked databases that match the provisioned naming pattern (e.g. created
--    before the tracking table existed). Falls back to sys.databases.create_date.
SELECT @sql = @sql +
    N''DROP DATABASE ['' + d.name + N''];'' + CHAR(13)
FROM sys.databases d
WHERE d.name LIKE N''%[_]%[_]dbss''
  AND d.create_date < @cutoff
  AND NOT EXISTS (
      SELECT 1 FROM master.dbo.ProvisionedDatabases p
      WHERE p.FullDatabaseName + N''_dbss'' = d.name
  );

SELECT @sql = @sql +
    N''DROP DATABASE ['' + d.name + N''];'' + CHAR(13)
FROM sys.databases d
WHERE d.name LIKE N''%[_]%''
  AND d.name NOT LIKE N''%[_]dbss''
  AND d.name NOT IN (N''master'', N''model'', N''msdb'', N''tempdb'')
  AND d.create_date < @cutoff
  AND NOT EXISTS (
      SELECT 1 FROM master.dbo.ProvisionedDatabases p
      WHERE p.FullDatabaseName = d.name
  );

IF @sql <> N''''
    EXEC sp_executesql @sql;

PRINT N''DatabaseProvisioner_Cleanup completed. Tracked databases dropped: '' + CAST(@dropped AS NVARCHAR(10));
';
GO

EXEC sp_add_schedule
    @schedule_name = N'DatabaseProvisioner_Cleanup_Daily',
    @freq_type = 4,          -- daily
    @freq_interval = 1,
    @active_start_time = 030000;  -- 3:00 AM
GO

EXEC sp_attach_schedule
    @job_name = N'DatabaseProvisioner_Cleanup',
    @schedule_name = N'DatabaseProvisioner_Cleanup_Daily';
GO

EXEC sp_add_jobserver
    @job_name = N'DatabaseProvisioner_Cleanup',
    @server_name = N'(LOCAL)';
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' AND status = 4
)
BEGIN
EXEC xp_cmdshell 'net start SQLSERVERAGENT', no_output = 1;
    WAITFOR
DELAY '00:00:05';
END
GO
