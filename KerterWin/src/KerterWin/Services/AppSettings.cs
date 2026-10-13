using System.Text.Json;

namespace KerterWin.Services;

public sealed class AppSettings
{
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KerterWin", "settings.json");

    /// Acelerador de conexión: el directo se graba en local con varias conexiones (ver `LiveProxy`).
    public bool ConnectionBooster { get; set; } = true;
    public double Volume { get; set; } = 100;

    public static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
    }
}
