# AGENTS.md

## Project overview

DatabaseProvisioner is an ASP.NET Core 9 minimal API that provisions isolated SQL Server databases for Cursor Background/Cloud agents. Each agent gets its own database restored from a shared `.bak` file, with a database snapshot created for fast reset.

The service runs on a shared Windows host alongside SQL Server. It is the only consumer of these databases.

## Build and run

```bash
dotnet build
dotnet run --launch-profile http
```

Listens on `http://localhost:3350` in Development. Production (deployed) uses `http://0.0.0.0:3340` (accessible on LAN).

## Deployment

Two scripts handle deployment and startup:

**Full deploy** — publishes, copies to `C:\Services\DatabaseProvisioner`, and starts the service:

```powershell
.\deploy.ps1
```

`deploy.ps1` also copies `run.ps1` into the deployment directory so it can be used independently.

**Start/restart without redeploying** — use `run.ps1` from the deployment directory (e.g. after a machine restart):

```powershell
C:\Services\DatabaseProvisioner\run.ps1
```

`run.ps1` accepts an optional `-ServicePath` parameter (defaults to the directory it lives in):

```powershell
.\run.ps1 -ServicePath "C:\Services\DatabaseProvisioner"
```

## Project structure

```
DatabaseProvisioner/                 # Repo root
  deploy.ps1                        # Publishes, copies to deploy dir (including run.ps1), and starts
  run.ps1                           # Stops any running instance and starts the exe (copied to deploy dir)
  DatabaseProvisioner/
    Program.cs                      # Minimal API endpoint definition
    DatabaseProvisioningService.cs  # Core provisioning logic (restore, snapshot, locking, tracking)
    AuthenticationMiddleware.cs     # X-Api-Key header validation
    Scripts/
      CreateOptimizedBackup.sql     # SQL script to produce an optimized .bak file
      CreateProvisionedDatabasesTable.sql  # One-time setup: tracking table in master
      CreateCleanupJob.sql          # One-time setup: SQL Agent Job for stale database cleanup
    Properties/
      launchSettings.json
    appsettings.json                # Connection string, API key
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
5. After any successful operation, the service upserts a row in `master.dbo.ProvisionedDatabases` with the current UTC timestamp. This tracking is non-critical — failures are logged as warnings without affecting the API response.

### Assumptions the SQL relies on

- The `.bak` file is in SQL Server's default backup directory.
- The backup's logical data file is named `{databaseName}` and log file is `{databaseName}_log`. If not, SQL Server will return an error — there is no pre-validation.
- Physical `.mdf`/`.ldf` paths are derived from `sys.database_files` on the master database.
- The snapshot `NAME` parameter references the logical data file name from the backup (`{databaseName}`), not the full database name.

## Testing

Start the app, then test with curl.

```bash
# Provision a new database
curl -s -X POST "http://localhost:3350/StaffingLogistics/20260223X3869" \
  -H "X-Api-Key: g9HcwjgTMlGbGR15Vy9fB24vV06o24rS"

# Idempotent re-call (returns already_exists)
curl -s -X POST "http://localhost:3350/StaffingLogistics/20260223X3869" \
  -H "X-Api-Key: g9HcwjgTMlGbGR15Vy9fB24vV06o24rS"

# Restore from snapshot
curl -s -X POST "http://localhost:3350/StaffingLogistics/20260223X3869?restoreFromSnapshot=true" \
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

## Database cleanup

Agent databases are short-lived (1–7 days). A SQL Server Agent Job (`DatabaseProvisioner_Cleanup`) runs daily at 3:00 AM and drops databases not accessed in the last 7 days.

### Tracking table

`master.dbo.ProvisionedDatabases` records every provisioned database with a `LastAccessedUtc` timestamp that is updated on every API call (provision, no-op, or snapshot restore). The cleanup job uses this timestamp rather than `sys.databases.create_date`, so actively-used databases are never dropped prematurely.

### Cleanup job behavior

1. Drops snapshot (`*_dbss`) and parent databases where `LastAccessedUtc` is older than 1 day.
2. Deletes the corresponding tracking rows.
3. Removes orphaned tracking rows (database was manually dropped).
4. Falls back to `sys.databases.create_date` for untracked databases matching the naming pattern (handles databases created before the tracking table existed).

### One-time setup

Run these scripts once against the SQL Server instance to create the tracking table and the Agent Job:

```bash
sqlcmd -i DatabaseProvisioner/Scripts/CreateProvisionedDatabasesTable.sql
sqlcmd -i DatabaseProvisioner/Scripts/CreateCleanupJob.sql
```

Verify the job exists in SQL Server Agent > Jobs > `DatabaseProvisioner_Cleanup`. Both scripts are idempotent.

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
