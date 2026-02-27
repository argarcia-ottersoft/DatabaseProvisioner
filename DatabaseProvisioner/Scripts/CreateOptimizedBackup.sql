-- CreateOptimizedBackup.sql
-- Creates a compressed, log-shrunk backup of StaffingLogistics for use with DatabaseProvisioner.
--
-- Prerequisites:
--   - Run on the server hosting the live StaffingLogistics database
--   - The backup path must be writable by the SQL Server service account
--   - Existing StaffingLogistics.bak at the default backup location will be overwritten
--
-- Usage:
--   sqlcmd -i CreateOptimizedBackup.sql

USE
[master];
GO

-- Switch to SIMPLE recovery to allow the log to be fully truncated.
-- The provisioner sets SIMPLE on restored copies anyway, so the backup
-- does not need to carry full recovery semantics.
ALTER
DATABASE [StaffingLogistics] SET RECOVERY SIMPLE;
GO

USE [StaffingLogistics];
GO

-- Truncate ClinicianEventTimesheetHistory to reduce backup size.
TRUNCATE TABLE dbo.ClinicianEventTimesheetHistory;
GO

-- Delete ScheduleShiftItem rows not referenced by any ClinicianEventShift.
-- Cannot TRUNCATE due to FK constraints, so delete in batches.
DECLARE
@deleted int = 1;
WHILE
@deleted > 0
BEGIN
    DELETE
TOP (500000) FROM dbo.ScheduleShiftItem
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.ClinicianEventShift c
        WHERE c.ScheduleShiftItemId = dbo.ScheduleShiftItem.Id
    );
    SET
@deleted = @@ROWCOUNT;
END
GO

-- Checkpoint and shrink files after clearing data.
CHECKPOINT;
GO

DBCC SHRINKFILE(StaffingLogistics, 0);
GO

DBCC SHRINKFILE(StaffingLogistics_log, 64);
GO

USE [master];
GO

-- Create a compressed backup, overwriting any existing file.
-- COMPRESSION typically achieves 4-6x reduction on this database.

BACKUP
DATABASE [StaffingLogistics]
TO DISK = 'StaffingLogistics.bak'
WITH
    FORMAT,
    COMPRESSION,
    MAXTRANSFERSIZE = 4194304,
    BUFFERCOUNT = 32,
    STATS = 10;
GO

-- Restore the original recovery model if needed for production log shipping / AG.
-- Uncomment the line below if the live database should remain in FULL recovery:
-- ALTER DATABASE [StaffingLogistics] SET RECOVERY FULL;
-- GO

PRINT 'Backup complete. Verify the file at the backup path.';
GO
