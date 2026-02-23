```sql
BACKUP DATABASE [StaffingLogistics] TO DISK = N'StaffingLogistics.bak' WITH FORMAT;

CREATE DATABASE [StaffingLogistics_dbss] ON
(NAME = N'StaffingLogistics', FILENAME = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\StaffingLogistics_data.ss')
AS SNAPSHOT OF [StaffingLogistics];
```
---
```sql
USE [master];

DECLARE @kill varchar(8000) = '';
SELECT @kill = @kill + 'kill ' + CONVERT(varchar(5), session_id) + ';'
FROM sys.dm_exec_sessions
WHERE database_id  = db_id('StaffingLogistics')

EXEC(@kill);


RESTORE DATABASE [StaffingLogistics] FROM
DATABASE_SNAPSHOT = N'StaffingLogistics_dbss';
```
---
```csharp
private static void InitializeDatabaseAsync(SqlConnection connection, string databaseName, bool useSnapshot = true)
    {
        var testDatabaseId = connection.ExecuteScalar<int?>("SELECT DB_ID(@databaseName)", new { databaseName });
        if (testDatabaseId != null)
        {
            if (!useSnapshot) return;

            var revertQuery = $@"
                USE [master];

                DECLARE @kill varchar(8000) = '';
                SELECT @kill = @kill + 'kill ' + CONVERT(varchar(5), session_id) + ';'
                FROM sys.dm_exec_sessions
                WHERE database_id  = db_id('{databaseName}')

                EXEC(@kill);

                RESTORE DATABASE [{databaseName}] FROM
                DATABASE_SNAPSHOT = N'{databaseName}_dbss';
            ";

            connection.Execute(revertQuery);
            return;
        }

        const string masterQuery = "SELECT TOP 1 physical_name from sys.database_files where type_desc = 'ROWS' ORDER BY file_id";
        var masterFile = connection.ExecuteScalar<string>(masterQuery);
        string dataDirectory = Path.GetDirectoryName(masterFile) ?? throw new ApplicationException("Could not find master file");

        const string masterLogQuery = "SELECT TOP 1 physical_name from sys.database_files where type_desc = 'LOG' ORDER BY file_id";
        var masterLogFile = connection.ExecuteScalar<string>(masterLogQuery);
        string logDirectory = Path.GetDirectoryName(masterLogFile) ?? throw new ApplicationException("Could not find master log file");

        Directory.CreateDirectory(dataDirectory);
        Directory.CreateDirectory(logDirectory);

        // replace with regex to remove the version number V\d+
        string databaseNameWithoutVersion = Regex.Replace(databaseName, "_V\\d+$", "", RegexOptions.IgnoreCase);
        string dataFile = Path.Combine(dataDirectory, $"{databaseName}.mdf");
        string logFile = Path.Combine(logDirectory, $"{databaseName}.ldf");
        string snapshotFile = Path.Combine(dataDirectory, $"{databaseName}_data.ss");

        var initializeQuery = $@"
            USE [master];

            RESTORE DATABASE [{databaseName}] FROM DISK = N'{databaseNameWithoutVersion}.bak'
	        WITH REPLACE, NOUNLOAD,
	        MOVE N'{databaseNameWithoutVersion}' TO N'{dataFile}',
	        MOVE N'{databaseNameWithoutVersion}_log' TO N'{logFile}'

	        ALTER DATABASE [{databaseName}] SET READ_WRITE WITH NO_WAIT;

            CREATE DATABASE [{databaseName}_dbss] ON
            (NAME = N'{databaseNameWithoutVersion}', FILENAME = N'{snapshotFile}')
            AS SNAPSHOT OF [{databaseName}];
        ";

        connection.Execute(initializeQuery);
    }
```