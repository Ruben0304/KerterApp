namespace KerterCore.Util;

/// Claves ClearKey: hex, UUID o base64/base64url → 16 bytes.
public static class DrmKeys
{
    public static byte[]? Bytes(string? input)
    {
        var clean = (input ?? "").Trim();
        if (clean.Length == 0) return null;
        if (clean.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) clean = clean[2..];
        var noDashes = clean.Replace("-", "").Replace(" ", "");
        if (noDashes.Length == 32)
            try { return Convert.FromHexString(noDashes); } catch (FormatException) { }
        var b64 = clean.Replace('-', '+').Replace('_', '/');
        if (b64.Length % 4 != 0) b64 += new string('=', 4 - b64.Length % 4);
        try
        {
            var d = Convert.FromBase64String(b64);
            if (d.Length == 16) return d;
        }
        catch (FormatException) { }
        return null;
    }

    public static string? CanonicalHex(string? input) =>
        Bytes(input) is { Length: 16 } d ? Convert.ToHexString(d).ToLowerInvariant() : null;
}
