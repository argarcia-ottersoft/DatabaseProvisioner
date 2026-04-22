USE [msdb];
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DatabaseProvisioner_Cleanup')
BEGIN
EXEC sp_delete_job @job_name = N'DatabaseProvisioner_Cleanup', @delete_unused_schedule = 1;
END
GO

EXEC sp_add_job
    @job_name = N'DatabaseProvisioner_Cleanup',
    @description = N'Drops provisioned agent databases not accessed in the last 2 hours. Handles orphaned tracking rows and untracked databases.';
GO

EXEC sp_add_jobstep
    @job_name = N'DatabaseProvisioner_Cleanup',
    @step_name = N'Drop stale databases and clean up tracking',
    @subsystem = N'TSQL',
    @database_name = N'master',
    @command = N'
DECLARE @cutoff DATETIME2 = DATEADD(HOUR, -2, SYSUTCDATETIME());
DECLARE @sql NVARCHAR(MAX) = N'''';
DECLARE @dropped INT = 0;

DECLARE @staleTracked TABLE
(
    FullDatabaseName NVARCHAR(256) NOT NULL PRIMARY KEY,
    AgentId NVARCHAR(128) NOT NULL,
    LoginName NVARCHAR(256) NOT NULL
);

DECLARE @orphanedTracked TABLE
(
    FullDatabaseName NVARCHAR(256) NOT NULL PRIMARY KEY,
    AgentId NVARCHAR(128) NOT NULL,
    LoginName NVARCHAR(256) NOT NULL
);

DECLARE @staleUntrackedDatabases TABLE
(
    FullDatabaseName NVARCHAR(256) NOT NULL PRIMARY KEY,
    AgentId NVARCHAR(128) NULL,
    LoginName NVARCHAR(256) NULL
);

DECLARE @staleUntrackedSnapshots TABLE
(
    SnapshotName NVARCHAR(256) NOT NULL PRIMARY KEY
);

DECLARE @loginCleanupCandidates TABLE
(
    LoginName NVARCHAR(256) NOT NULL PRIMARY KEY
);

-- 1. Gather tracked databases that are past the retention period.
INSERT INTO @staleTracked (FullDatabaseName, AgentId, LoginName)
SELECT
    FullDatabaseName,
    AgentId,
    N''logisticsDev_'' + AgentId
FROM master.dbo.ProvisionedDatabases
WHERE LastAccessedUtc < @cutoff;

-- 2. Gather orphaned tracking rows where the database is already gone.
INSERT INTO @orphanedTracked (FullDatabaseName, AgentId, LoginName)
SELECT
    FullDatabaseName,
    AgentId,
    N''logisticsDev_'' + AgentId
FROM master.dbo.ProvisionedDatabases
WHERE DB_ID(FullDatabaseName) IS NULL;

-- 3. Gather untracked parent databases that match the provisioned naming pattern.
INSERT INTO @staleUntrackedDatabases (FullDatabaseName, AgentId, LoginName)
SELECT
    d.name,
    CASE
        WHEN CHARINDEX(N''_'', REVERSE(d.name)) > 0
        THEN RIGHT(d.name, CHARINDEX(N''_'', REVERSE(d.name)) - 1)
    END,
    CASE
        WHEN CHARINDEX(N''_'', REVERSE(d.name)) > 0
        THEN N''logisticsDev_'' + RIGHT(d.name, CHARINDEX(N''_'', REVERSE(d.name)) - 1)
    END
FROM sys.databases d
WHERE d.name LIKE N''%[_][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]X%''
  AND d.name NOT LIKE N''%[_]dbss''
  AND d.create_date < @cutoff
  AND NOT EXISTS (
      SELECT 1
      FROM master.dbo.ProvisionedDatabases p
      WHERE p.FullDatabaseName = d.name
  );

-- 4. Gather lingering untracked snapshots so they can be dropped as well.
INSERT INTO @staleUntrackedSnapshots (SnapshotName)
SELECT d.name
FROM sys.databases d
WHERE d.name LIKE N''%[_][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]X%[_]dbss''
  AND d.create_date < @cutoff
  AND NOT EXISTS (
      SELECT 1
      FROM master.dbo.ProvisionedDatabases p
      WHERE p.FullDatabaseName + N''_dbss'' = d.name
  );

-- 5. Drop tracked and untracked databases. Snapshots must be dropped first.
DECLARE @fullDatabaseName NVARCHAR(256);
DECLARE @snapshotName NVARCHAR(256);
DECLARE @loginName NVARCHAR(256);

DECLARE database_cleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT FullDatabaseName FROM @staleTracked
UNION
SELECT FullDatabaseName FROM @staleUntrackedDatabases;

OPEN database_cleanup;
FETCH NEXT FROM database_cleanup INTO @fullDatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N''IF DB_ID(@snapshotDatabaseName) IS NOT NULL DROP DATABASE ''
             + QUOTENAME(@fullDatabaseName + N''_dbss'') + N'';'' + CHAR(13)
             + N''IF DB_ID(@databaseName) IS NOT NULL DROP DATABASE ''
             + QUOTENAME(@fullDatabaseName) + N'';'';

    EXEC sp_executesql
        @sql,
        N''@snapshotDatabaseName SYSNAME, @databaseName SYSNAME'',
        @snapshotDatabaseName = @fullDatabaseName + N''_dbss'',
        @databaseName = @fullDatabaseName;
    FETCH NEXT FROM database_cleanup INTO @fullDatabaseName;
END

CLOSE database_cleanup;
DEALLOCATE database_cleanup;

DECLARE snapshot_cleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT SnapshotName FROM @staleUntrackedSnapshots;

OPEN snapshot_cleanup;
FETCH NEXT FROM snapshot_cleanup INTO @snapshotName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N''IF DB_ID(@databaseName) IS NOT NULL DROP DATABASE ''
             + QUOTENAME(@snapshotName) + N'';'';

    EXEC sp_executesql
        @sql,
        N''@databaseName SYSNAME'',
        @databaseName = @snapshotName;
    FETCH NEXT FROM snapshot_cleanup INTO @snapshotName;
END

CLOSE snapshot_cleanup;
DEALLOCATE snapshot_cleanup;

SELECT @dropped = (SELECT COUNT(*) FROM @staleTracked) + (SELECT COUNT(*) FROM @staleUntrackedDatabases);

-- 6. Remove tracking rows after database cleanup.
DELETE p
FROM master.dbo.ProvisionedDatabases p
JOIN @staleTracked st ON st.FullDatabaseName = p.FullDatabaseName;

DELETE p
FROM master.dbo.ProvisionedDatabases p
JOIN @orphanedTracked ot ON ot.FullDatabaseName = p.FullDatabaseName;

-- 7. Collect candidate logins for cleanup.
INSERT INTO @loginCleanupCandidates (LoginName)
SELECT DISTINCT LoginName
FROM (
    SELECT LoginName FROM @staleTracked
    UNION ALL
    SELECT LoginName FROM @orphanedTracked
    UNION ALL
    SELECT LoginName
    FROM @staleUntrackedDatabases
    WHERE LoginName IS NOT NULL
) candidates;

-- 8. Drop matching logins for cleaned-up databases.
DECLARE login_cleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT LoginName
FROM @loginCleanupCandidates;

OPEN login_cleanup;
FETCH NEXT FROM login_cleanup INTO @loginName;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF SUSER_ID(@loginName) IS NOT NULL
    BEGIN
        SET @sql = N''DROP LOGIN '' + QUOTENAME(@loginName) + N'';'';
        EXEC sp_executesql @sql;
    END

    FETCH NEXT FROM login_cleanup INTO @loginName;
END

CLOSE login_cleanup;
DEALLOCATE login_cleanup;

PRINT N''DatabaseProvisioner_Cleanup completed. Databases dropped: '' + CAST(@dropped AS NVARCHAR(10));
';
GO

EXEC sp_add_schedule
    @schedule_name = N'DatabaseProvisioner_Cleanup_Hourly',
    @freq_type = 4,          -- recurring schedule with hourly subday interval below
    @freq_interval = 1,
    @freq_subday_type = 8,   -- hours
    @freq_subday_interval = 1,
    @active_start_time = 000000,
    @active_end_time = 235959;
GO

EXEC sp_attach_schedule
    @job_name = N'DatabaseProvisioner_Cleanup',
    @schedule_name = N'DatabaseProvisioner_Cleanup_Hourly';
GO

EXEC sp_add_jobserver
    @job_name = N'DatabaseProvisioner_Cleanup',
    @server_name = N'(LOCAL)';
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' AND status = 4
)
BEGIN
    EXEC xp_cmdshell 'net start SQLSERVERAGENT', no_output;
    WAITFOR DELAY '00:00:05';
END
GO
