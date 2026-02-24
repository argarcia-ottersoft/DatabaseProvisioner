using DatabaseProvisioner;
using DatabaseProvisioningService = DatabaseProvisioner.DatabaseProvisioningService;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOpenApi();
builder.Services.AddSingleton<DatabaseProvisioningService>();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseMiddleware<AuthenticationMiddleware>();

app.MapPost("/{databaseName}/{id}", async (
    string databaseName,
    string id,
    bool? restoreFromSnapshot,
    DatabaseProvisioningService service,
    CancellationToken ct) =>
{
    var fullDatabaseName = $"{databaseName}_{id}";

    try
    {
        var result = await service.ProvisionAsync(databaseName, id, restoreFromSnapshot ?? false, ct);

        return result switch
        {
            ProvisionResult.Created => Results.Created($"/{databaseName}/{id}",
                new { database = fullDatabaseName, status = "created" }),
            ProvisionResult.AlreadyExists => Results.Ok(new { database = fullDatabaseName, status = "already_exists" }),
            ProvisionResult.RestoredFromSnapshot => Results.Ok(new
                { database = fullDatabaseName, status = "restored_from_snapshot" }),
            _ => Results.StatusCode(500)
        };
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message, statusCode: 500);
    }
});

app.Run();