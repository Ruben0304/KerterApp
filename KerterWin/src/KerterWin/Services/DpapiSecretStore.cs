using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KerterCore.Api;

namespace KerterWin.Services;

/// Secretos (token, credenciales) cifrados con DPAPI del usuario de Windows.
public sealed class DpapiSecretStore : ISecretStore
{
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KerterWin", "secrets.json");

    private readonly Dictionary<string, string> _data;

    public DpapiSecretStore()
    {
        try { _data = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(FilePath)) ?? []; }
        catch { _data = []; }
    }

    public string? Get(string key)
    {
        if (!_data.TryGetValue(key, out var v)) return null;
        try
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(v), null, DataProtectionScope.CurrentUser));
        }
        catch { return null; }
    }

    public void Set(string key, string value)
    {
        _data[key] = Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
        Save();
    }

    public void Remove(string key)
    {
        if (_data.Remove(key)) Save();
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(_data));
    }
}
