using DatabaseProvisioner;
using DatabaseProvisioningService = DatabaseProvisioner.DatabaseProvisioningService;

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

builder.Services.AddOpenApi();
builder.Services.AddSingleton<DatabaseProvisioningService>();

WebApplication app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();
app.UseMiddleware<AuthenticationMiddleware>();

app.MapPost("/api/provision-database/{id}", async (
    string id,
    ProvisionRequest? request,
    DatabaseProvisioningService service,
    CancellationToken ct) =>
{
    bool restoreFromSnapshot = request?.RestoreFromSnapshot ?? false;

    try
    {
        ProvisionResult result = await service.ProvisionAsync(id, restoreFromSnapshot, ct);

        return result switch
        {
            ProvisionResult.Created => Results.Created($"/api/provision-database/{id}", new { database = id, status = "created" }),
            ProvisionResult.AlreadyExists => Results.Ok(new { database = id, status = "already_exists" }),
            ProvisionResult.RestoredFromSnapshot => Results.Ok(new { database = id, status = "restored_from_snapshot" }),
            _ => Results.StatusCode(500)
        };
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message, statusCode: 500);
    }
});

app.Run();

public record ProvisionRequest(bool RestoreFromSnapshot = false);