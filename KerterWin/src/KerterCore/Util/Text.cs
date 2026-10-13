using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace KerterCore.Util;

public static partial class Text
{
    /// Sin acentos y en minúsculas.
    public static string Fold(string s)
    {
        var d = s.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (var ch in d)
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) sb.Append(ch);
        return sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    [GeneratedRegex("[^a-z0-9 ]")]
    private static partial Regex NonAlnum();

    /// "Bosnia-Herzegovina" → "bosnia herzegovina".
    public static string Key(string s) =>
        string.Join(' ', NonAlnum().Replace(Fold(s), " ").Split(' ', StringSplitOptions.RemoveEmptyEntries));

    private static readonly string[] Noise = [" fc", "fc ", " cf", "cf ", " sc", " ac", " club", " de futbol", " futbol"];

    /// Nombre de equipo sin acentos ni sufijos de club.
    public static string NormalizeTeam(string s)
    {
        var o = NonAlnum().Replace(Fold(s), " ");
        foreach (var n in Noise) o = o.Replace(n, " ");
        return string.Join(' ', o.Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// Mismo equipo ignorando acentos, mayúsculas y sufijos de club; selecciones por código FIFA.
    public static bool SimilarTeam(string a, string b)
    {
        var ca = NationalTeams.Code(a);
        var cb = NationalTeams.Code(b);
        if (ca != null && cb != null) return ca == cb;
        var x = NormalizeTeam(a);
        var y = NormalizeTeam(b);
        if (x.Length <= 2 || y.Length <= 2) return false;
        return x == y || x.Contains(y) || y.Contains(x);
    }

    /// Como `URLSearchParams`: espacios a `+` y todo lo que no sea alfanumérico ASCII o `-._*`, escapado.
    public static string FormEncode(IEnumerable<(string Name, string Value)> items) =>
        string.Join('&', items.Select(i => $"{i.Name}={FormValue(i.Value)}"));

    private static string FormValue(string v)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(v))
        {
            var c = (char)b;
            if (b < 128 && (char.IsAsciiLetterOrDigit(c) || "-._*".Contains(c))) sb.Append(c);
            else if (c == ' ') sb.Append('+');
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }
}

public static partial class NationalTeams
{
    private static readonly Lazy<Dictionary<string, string>> Index = new(() =>
    {
        var map = new Dictionary<string, string>();
        foreach (var (code, name, english) in Entries)
            foreach (var v in new[] { name, english, code }) map[Text.Key(v)] = code;
        foreach (var (alias, code) in Aliases) map[Text.Key(alias)] = code;
        return map;
    });

    /// Código FIFA de la selección que nombra `team` en cualquier idioma.
    public static string? Code(string team) => Index.Value.GetValueOrDefault(Text.Key(team));
}
