using Dapper;
using Microsoft.Data.SqlClient;

namespace DatabaseProvisioner;

public enum ProvisionResult
{
    Created,
    AlreadyExists,
    RestoredFromSnapshot
}

public class DatabaseProvisioningService(IConfiguration configuration, ILogger<DatabaseProvisioningService> logger)
{
    private string ConnectionString => configuration.GetConnectionString("DefaultConnection")
                                       ?? throw new InvalidOperationException(
                                           "Missing ConnectionStrings:DefaultConnection");

    public async Task<ProvisionResult> ProvisionAsync(string databaseName, string id, bool restoreFromSnapshot,
        CancellationToken ct = default)
    {
        var fullDatabaseName = $"{databaseName}_{id}";

        await using var connection = new SqlConnection(ConnectionString);
        await connection.OpenAsync(ct);

        var databaseId = await connection.ExecuteScalarAsync<int?>(
            "SELECT DB_ID(@fullDatabaseName)", new { fullDatabaseName });

        if (databaseId is not null)
        {
            if (!restoreFromSnapshot)
            {
                logger.LogInformation("Database {Database} already exists, no-op", fullDatabaseName);
                return ProvisionResult.AlreadyExists;
            }

            logger.LogInformation("Restoring {Database} from snapshot", fullDatabaseName);
            await RestoreFromSnapshotAsync(connection, fullDatabaseName);
            return ProvisionResult.RestoredFromSnapshot;
        }

        logger.LogInformation("Creating {Database} from backup {Backup}", fullDatabaseName, databaseName);
        await RestoreFromBackupAsync(connection, databaseName, fullDatabaseName);
        return ProvisionResult.Created;
    }

    private static async Task RestoreFromSnapshotAsync(SqlConnection connection, string fullDatabaseName)
    {
        var query = $"""
                     USE [master];

                     DECLARE @kill varchar(8000) = '';
                     SELECT @kill = @kill + 'kill ' + CONVERT(varchar(5), session_id) + ';'
                     FROM sys.dm_exec_sessions
                     WHERE database_id = db_id('{fullDatabaseName}')

                     EXEC(@kill);

                     RESTORE DATABASE [{fullDatabaseName}] FROM
                     DATABASE_SNAPSHOT = N'{fullDatabaseName}_dbss';
                     """;

        await connection.ExecuteAsync(query, commandTimeout: 120);
    }

    private static async Task RestoreFromBackupAsync(SqlConnection connection, string databaseName,
        string fullDatabaseName)
    {
        const string dataPathQuery =
            "SELECT TOP 1 physical_name FROM sys.database_files WHERE type_desc = 'ROWS' ORDER BY file_id";
        var masterFile = await connection.ExecuteScalarAsync<string>(dataPathQuery)
                         ?? throw new InvalidOperationException(
                             "Could not determine data directory from master database files");
        var dataDirectory = Path.GetDirectoryName(masterFile)
                            ?? throw new InvalidOperationException("Could not resolve data directory");

        const string logPathQuery =
            "SELECT TOP 1 physical_name FROM sys.database_files WHERE type_desc = 'LOG' ORDER BY file_id";
        var masterLogFile = await connection.ExecuteScalarAsync<string>(logPathQuery)
                            ?? throw new InvalidOperationException(
                                "Could not determine log directory from master database files");
        var logDirectory = Path.GetDirectoryName(masterLogFile)
                           ?? throw new InvalidOperationException("Could not resolve log directory");

        var dataFile = Path.Combine(dataDirectory, $"{fullDatabaseName}.mdf");
        var logFile = Path.Combine(logDirectory, $"{fullDatabaseName}.ldf");
        var snapshotFile = Path.Combine(dataDirectory, $"{fullDatabaseName}_dbss.ss");

        var restoreQuery = $"""
                            USE [master];

                            RESTORE DATABASE [{fullDatabaseName}] FROM DISK = N'{databaseName}.bak'
                            WITH REPLACE, NOUNLOAD,
                            MOVE N'{databaseName}' TO N'{dataFile}',
                            MOVE N'{databaseName}_log' TO N'{logFile}'

                            ALTER DATABASE [{fullDatabaseName}] SET READ_WRITE WITH NO_WAIT;
                            """;

        await connection.ExecuteAsync(restoreQuery, commandTimeout: 300);

        var snapshotQuery = $"""
                             USE [master];

                             CREATE DATABASE [{fullDatabaseName}_dbss] ON
                             (NAME = [{databaseName}], FILENAME = N'{snapshotFile}')
                             AS SNAPSHOT OF [{fullDatabaseName}];
                             """;

        await connection.ExecuteAsync(snapshotQuery, commandTimeout: 120);
    }
}