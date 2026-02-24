USE
[master];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'ProvisionedDatabases' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
CREATE TABLE dbo.ProvisionedDatabases
(
    FullDatabaseName NVARCHAR(256)  NOT NULL PRIMARY KEY,
    DatabaseName     NVARCHAR(128)  NOT NULL,
    AgentId          NVARCHAR(128)  NOT NULL,
    CreatedAtUtc     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    LastAccessedUtc  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
END
GO
