using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace DatabaseProvisioner;

public enum ProvisionResult
{
    Created,
    AlreadyExists,
    RestoredFromSnapshot
}

public partial class DatabaseProvisioningService(IConfiguration configuration, ILogger<DatabaseProvisioningService> logger)
{
    private string ConnectionString => configuration.GetConnectionString("DefaultConnection")
                                       ?? throw new InvalidOperationException("Missing ConnectionStrings:DefaultConnection");

    public async Task<ProvisionResult> ProvisionAsync(string databaseName, bool restoreFromSnapshot, CancellationToken ct = default)
    {
        await using var connection = new SqlConnection(ConnectionString);
        await connection.OpenAsync(ct);

        var databaseId = await connection.ExecuteScalarAsync<int?>(
            "SELECT DB_ID(@databaseName)", new { databaseName });

        if (databaseId is not null)
        {
            if (!restoreFromSnapshot)
            {
                logger.LogInformation("Database {Database} already exists, no-op", databaseName);
                return ProvisionResult.AlreadyExists;
            }

            logger.LogInformation("Restoring {Database} from snapshot", databaseName);
            await RestoreFromSnapshotAsync(connection, databaseName);
            return ProvisionResult.RestoredFromSnapshot;
        }

        logger.LogInformation("Creating {Database} from backup", databaseName);
        await RestoreFromBackupAsync(connection, databaseName);
        return ProvisionResult.Created;
    }

    private static async Task RestoreFromSnapshotAsync(SqlConnection connection, string databaseName)
    {
        var query = $"""
                     USE [master];

                     DECLARE @kill varchar(8000) = '';
                     SELECT @kill = @kill + 'kill ' + CONVERT(varchar(5), session_id) + ';'
                     FROM sys.dm_exec_sessions
                     WHERE database_id = db_id('{databaseName}')

                     EXEC(@kill);

                     RESTORE DATABASE [{databaseName}] FROM
                     DATABASE_SNAPSHOT = N'{databaseName}_dbss';
                     """;

        await connection.ExecuteAsync(query, commandTimeout: 120);
    }

    private static async Task RestoreFromBackupAsync(SqlConnection connection, string databaseName)
    {
        const string dataPathQuery = "SELECT TOP 1 physical_name FROM sys.database_files WHERE type_desc = 'ROWS' ORDER BY file_id";
        string masterFile = await connection.ExecuteScalarAsync<string>(dataPathQuery)
                            ?? throw new InvalidOperationException("Could not determine data directory from master database files");
        string dataDirectory = Path.GetDirectoryName(masterFile)
                               ?? throw new InvalidOperationException("Could not resolve data directory");

        const string logPathQuery = "SELECT TOP 1 physical_name FROM sys.database_files WHERE type_desc = 'LOG' ORDER BY file_id";
        string masterLogFile = await connection.ExecuteScalarAsync<string>(logPathQuery)
                               ?? throw new InvalidOperationException("Could not determine log directory from master database files");
        string logDirectory = Path.GetDirectoryName(masterLogFile)
                              ?? throw new InvalidOperationException("Could not resolve log directory");

        string backupName = StripVersionSuffix().Replace(databaseName, "");
        string dataFile = Path.Combine(dataDirectory, $"{databaseName}.mdf");
        string logFile = Path.Combine(logDirectory, $"{databaseName}.ldf");

        var query = $"""
                     USE [master];

                     RESTORE DATABASE [{databaseName}] FROM DISK = N'{backupName}.bak'
                     WITH REPLACE, NOUNLOAD,
                     MOVE N'{backupName}' TO N'{dataFile}',
                     MOVE N'{backupName}_log' TO N'{logFile}'

                     ALTER DATABASE [{databaseName}] SET READ_WRITE WITH NO_WAIT;
                     """;

        await connection.ExecuteAsync(query, commandTimeout: 300);
    }

    [GeneratedRegex(@"_V\d+$", RegexOptions.IgnoreCase)]
    private static partial Regex StripVersionSuffix();
}