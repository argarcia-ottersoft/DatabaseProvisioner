# AGENTS.md

## Project overview

DatabaseProvisioner is an ASP.NET Core 9 minimal API that provisions isolated SQL Server databases for Cursor Background/Cloud agents. Each agent gets its own database restored from a shared `.bak` file, with a database snapshot created for fast reset.

The service runs on a shared Windows host alongside SQL Server. It is the only consumer of these databases.

## Build and run

```bash
dotnet build
dotnet run --launch-profile https
```

Listens on `https://localhost:3341` and `http://localhost:3340`.

## Project structure

```
DatabaseProvisioner/
  Program.cs                        # Minimal API endpoint definition
  DatabaseProvisioningService.cs    # Core provisioning logic (restore, snapshot, locking)
  AuthenticationMiddleware.cs       # X-Api-Key header validation
  Scripts/
    CreateOptimizedBackup.sql       # SQL script to produce an optimized .bak file
  Properties/
    launchSettings.json
  appsettings.json                  # Connection string, API key
```

There is no test project. Test manually with curl against a running instance (see Testing section).

## API

Single endpoint:

```
POST /{databaseName}/{id}?restoreFromSnapshot=false
Header: X-Api-Key: <value from appsettings.json>
```

- `databaseName` — base name matching a `.bak` file in SQL Server's default backup directory (e.g. `StaffingLogistics`)
- `id` — unique agent identifier (e.g. `20260223X3869`)
- `restoreFromSnapshot` — optional query param, defaults to `false`

The resulting database is named `{databaseName}_{id}` with a snapshot `{databaseName}_{id}_dbss`.

### Responses

| Status | Meaning |
|--------|---------|
| 201 | Database created from backup + snapshot created |
| 200 | Database already exists (no-op) or restored from snapshot |
| 401 | Missing or invalid API key |
| 500 | SQL Server error (e.g. missing .bak file) |

## How provisioning works

1. A per-database `SemaphoreSlim` serializes concurrent requests for the same `{databaseName}_{id}`, preventing duplicate restore attempts.
2. `DB_ID()` checks if the database already exists.
3. If not, `RESTORE DATABASE` creates it from `{databaseName}.bak` using optimized buffer settings (`MAXTRANSFERSIZE = 4194304, BUFFERCOUNT = 32`), then sets `RECOVERY SIMPLE` and creates a database snapshot.
4. If it exists and `restoreFromSnapshot=true`, the snapshot is used to reset the database to its initial state.

### Assumptions the SQL relies on

- The `.bak` file is in SQL Server's default backup directory.
- The backup's logical data file is named `{databaseName}` and log file is `{databaseName}_log`. If not, SQL Server will return an error — there is no pre-validation.
- Physical `.mdf`/`.ldf` paths are derived from `sys.database_files` on the master database.
- The snapshot `NAME` parameter references the logical data file name from the backup (`{databaseName}`), not the full database name.

## Testing

Start the app, then test with curl. Use `-k` to skip TLS verification in dev.

```bash
# Provision a new database
curl -s -k -X POST "https://localhost:3341/StaffingLogistics/20260223X3869" \
  -H "X-Api-Key: g9HcwjgTMlGbGR15Vy9fB24vV06o24rS"

# Idempotent re-call (returns already_exists)
curl -s -k -X POST "https://localhost:3341/StaffingLogistics/20260223X3869" \
  -H "X-Api-Key: g9HcwjgTMlGbGR15Vy9fB24vV06o24rS"

# Restore from snapshot
curl -s -k -X POST "https://localhost:3341/StaffingLogistics/20260223X3869?restoreFromSnapshot=true" \
  -H "X-Api-Key: g9HcwjgTMlGbGR15Vy9fB24vV06o24rS"
```

To clean up test databases:

```sql
DROP DATABASE [StaffingLogistics_20260223X3869_dbss];
DROP DATABASE [StaffingLogistics_20260223X3869];
```

## Creating an optimized backup

Run `Scripts/CreateOptimizedBackup.sql` against the live database to produce a compressed, trimmed `.bak` file. The script truncates unnecessary tables (`CainApiLogDetail`, `ClinicianEventTimesheetHistory`), deletes orphaned `ScheduleShiftItem` rows, shrinks files, and backs up with compression.

```bash
sqlcmd -i DatabaseProvisioner/Scripts/CreateOptimizedBackup.sql
```

## Code conventions

- C# 12 / .NET 9, nullable reference types enabled, implicit usings.
- Minimal API style — no controllers. The single endpoint is defined inline in `Program.cs`.
- Dapper for all SQL queries, no Entity Framework.
- SQL is written as raw interpolated strings. Parameters that are used in DDL/identifiers are string-interpolated (SQL Server parameterization does not support identifiers). Parameters used in DML `WHERE` clauses use Dapper's `@param` syntax.
- The service is registered as a singleton. Concurrency is handled via a static `ConcurrentDictionary<string, SemaphoreSlim>`.
- Do not add input validation or pre-checks for `.bak` file existence — let SQL Server fail naturally.

## Security notes

- `appsettings.json` contains the API key in plaintext. Do not commit secrets to public repositories. The key shown in the repo is for the internal dev/staging server only.
- The connection string uses `Trusted_Connection=True` (Windows auth). The app must run under an account with SQL Server sysadmin privileges to perform `RESTORE DATABASE`.
