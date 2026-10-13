using System.Text.Json;

namespace KerterCore.Util;

/// Lectura tolerante del JSON del backend, cuyos nombres de campo varían.
public static class Json
{
    public static string? FirstString(this JsonElement e, params string[] keys)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        foreach (var k in keys)
        {
            if (!e.TryGetProperty(k, out var v)) continue;
            var s = v.ValueKind switch
            {
                JsonValueKind.String => v.GetString(),
                JsonValueKind.Number => v.GetRawText(),
                _ => null,
            };
            if (!string.IsNullOrEmpty(s)) return s;
        }
        return null;
    }

    public static bool? FirstBool(this JsonElement e, params string[] keys)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        foreach (var k in keys)
            if (e.TryGetProperty(k, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False)
                return v.GetBoolean();
        return null;
    }

    public static JsonElement? Obj(this JsonElement e, string key) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Object ? v : null;
}
