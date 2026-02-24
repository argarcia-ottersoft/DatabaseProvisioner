using System.Collections.Concurrent;
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
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Locks = new();

    private string ConnectionString => configuration.GetConnectionString("DefaultConnection")
                                       ?? throw new InvalidOperationException(
                                           "Missing ConnectionStrings:DefaultConnection");

    public async Task<ProvisionResult> ProvisionAsync(string databaseName, string id, bool restoreFromSnapshot,
        CancellationToken ct = default)
    {
        var fullDatabaseName = $"{databaseName}_{id}";
        var semaphore = Locks.GetOrAdd(fullDatabaseName, _ => new SemaphoreSlim(1, 1));

        await semaphore.WaitAsync(ct);
        try
        {
            await using var connection = new SqlConnection(ConnectionString);
            await connection.OpenAsync(ct);

            var databaseId = await connection.ExecuteScalarAsync<int?>(
                "SELECT DB_ID(@fullDatabaseName)", new { fullDatabaseName });

            ProvisionResult result;

            if (databaseId is not null)
            {
                if (!restoreFromSnapshot)
                {
                    logger.LogInformation("Database {Database} already exists, no-op", fullDatabaseName);
                    result = ProvisionResult.AlreadyExists;
                }
                else
                {
                    logger.LogInformation("Restoring {Database} from snapshot", fullDatabaseName);
                    await RestoreFromSnapshotAsync(connection, fullDatabaseName);
                    result = ProvisionResult.RestoredFromSnapshot;
                }
            }
            else
            {
                logger.LogInformation("Creating {Database} from backup {Backup}", fullDatabaseName, databaseName);
                await RestoreFromBackupAsync(connection, databaseName, fullDatabaseName);
                result = ProvisionResult.Created;
            }

            await TrackProvisionedDatabaseAsync(connection, fullDatabaseName, databaseName, id);

            return result;
        }
        finally
        {
            semaphore.Release();
        }
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
                            MAXTRANSFERSIZE = 4194304,
                            BUFFERCOUNT = 32,
                            STATS = 10,
                            MOVE N'{databaseName}' TO N'{dataFile}',
                            MOVE N'{databaseName}_log' TO N'{logFile}'

                            ALTER DATABASE [{fullDatabaseName}] SET READ_WRITE WITH NO_WAIT;
                            ALTER DATABASE [{fullDatabaseName}] SET RECOVERY SIMPLE WITH NO_WAIT;
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

    private async Task TrackProvisionedDatabaseAsync(SqlConnection connection, string fullDatabaseName,
        string databaseName, string id)
    {
        try
        {
            await connection.ExecuteAsync("""
                MERGE master.dbo.ProvisionedDatabases AS target
                USING (SELECT @fullDatabaseName, @databaseName, @id)
                    AS source (FullDatabaseName, DatabaseName, AgentId)
                ON target.FullDatabaseName = source.FullDatabaseName
                WHEN MATCHED THEN
                    UPDATE SET LastAccessedUtc = SYSUTCDATETIME()
                WHEN NOT MATCHED THEN
                    INSERT (FullDatabaseName, DatabaseName, AgentId)
                    VALUES (source.FullDatabaseName, source.DatabaseName, source.AgentId);
                """, new { fullDatabaseName, databaseName, id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to upsert tracking row for {Database}", fullDatabaseName);
        }
    }
}