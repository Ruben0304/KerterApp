using System.Net;
using System.Text;
using System.Text.Json;
using KerterCore.Models;
using KerterCore.Util;

namespace KerterCore.Api;

public sealed class ApiException(HttpStatusCode? status, string message) : Exception(message)
{
    public HttpStatusCode? Status { get; } = status;
    public bool IsUnauthorized => Status == HttpStatusCode.Unauthorized;
}

/// Cliente HTTP hacia el backend de Kerter+.
public sealed class KerterApi
{
    public static readonly Uri BaseUrl = new("https://kerterplus.duckdns.org/api");
    public static readonly Uri MediaBase = new("https://cdn.socy.cloud");

    private readonly HttpClient _http;

    /// Token Bearer actual; lo pone `AuthService` al iniciar sesión.
    public string? AuthToken { get; set; }

    public KerterApi(HttpClient? http = null) => _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(20) };

    /// Devuelve (token, usuario).
    public async Task<(string? Token, User? User)> LoginAsync(string email, string password, CancellationToken ct = default)
    {
        var body = JsonSerializer.Serialize(new { email, password });
        using var doc = await SendAsync("/auth/login", HttpMethod.Post, body, ct);
        var root = doc.RootElement;
        string[] tokenKeys = ["token", "accessToken", "access_token", "jwt", "authToken", "idToken", "bearer", "session"];
        var data = root.Obj("data");
        var token = root.FirstString(tokenKeys) ?? data?.FirstString(tokenKeys);
        var user = root.Obj("user") is { } u ? User.From(u)
            : data?.Obj("user") is { } u2 ? User.From(u2)
            : data is { } d ? User.From(d) : User.From(root);
        return (token, user);
    }

    public async Task<List<Channel>> FetchChannelsAsync(CancellationToken ct = default)
    {
        using var doc = await SendAsync("/channels/public", HttpMethod.Get, null, ct);
        var root = doc.RootElement;
        JsonElement list = root;
        if (root.ValueKind == JsonValueKind.Object)
        {
            list = default;
            foreach (var k in new[] { "data", "channels", "results", "items" })
                if (root.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array) { list = v; break; }
        }
        if (list.ValueKind != JsonValueKind.Array) throw new ApiException(null, "Formato de lista de canales desconocido.");
        return list.EnumerateArray().Select(e => Channel.FromJson(e, MediaBase)).ToList();
    }

    /// Cartelera: asignaciones evento → canal para una fecha (yyyy-MM-dd).
    public async Task<List<Assignment>> FetchAssignmentsAsync(string date, CancellationToken ct = default)
    {
        using var doc = await SendAsync($"/assignments?date={date}", HttpMethod.Get, null, ct);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Array) return [];
        return root.EnumerateArray().Select(Assignment.From).ToList();
    }

    private async Task<JsonDocument> SendAsync(string path, HttpMethod method, string? body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(method, BaseUrl.AbsoluteUri + path);
        req.Headers.Accept.ParseAdd("application/json");
        if (body != null) req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        if (AuthToken != null) req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + AuthToken);
        using var resp = await _http.SendAsync(req, ct);
        var bytes = await resp.Content.ReadAsByteArrayAsync(ct);
        if (!resp.IsSuccessStatusCode)
        {
            string? msg = null;
            try
            {
                using var d = JsonDocument.Parse(bytes);
                msg = d.RootElement.FirstString("message", "error", "msg");
            }
            catch (JsonException) { }
            if (resp.StatusCode == HttpStatusCode.Unauthorized) msg = "Sesión expirada o credenciales incorrectas.";
            throw new ApiException(resp.StatusCode, msg ?? $"Error del servidor ({(int)resp.StatusCode}).");
        }
        try { return JsonDocument.Parse(bytes); }
        catch (JsonException) { throw new ApiException(null, "No se pudo interpretar la respuesta del servidor."); }
    }
}
