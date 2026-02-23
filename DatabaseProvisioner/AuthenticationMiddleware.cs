namespace DatabaseProvisioner;

public class AuthenticationMiddleware(RequestDelegate next, IConfiguration configuration)
{
    private const string ApiKeyHeaderName = "X-Api-Key";

    public async Task InvokeAsync(HttpContext context)
    {
        if (!context.Request.Headers.TryGetValue(ApiKeyHeaderName, out var providedKey))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsync("Missing API key");
            return;
        }

        var expectedKey = configuration["ApiKey"]
                          ?? throw new InvalidOperationException("Missing ApiKey configuration");

        if (!string.Equals(providedKey, expectedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsync("Invalid API key");
            return;
        }

        await next(context);
    }
}