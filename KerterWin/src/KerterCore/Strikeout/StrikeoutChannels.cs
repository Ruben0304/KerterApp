using KerterCore.Models;
using KerterCore.Util;

namespace KerterCore.Strikeout;

/// Suma los streams de strikeout.im como canales extra de los partidos de la cartelera: mismo partido
/// (ambos equipos, en cualquier idioma u orden) → sus "Stream 1…N" aparecen junto a los de Kerter.
public sealed class StrikeoutChannels
{
    /// Los ids de Kerter son pequeños: por encima de esto son de Strikeout.
    private const int IdBase = 1_900_000_000;

    private readonly Dictionary<int, List<StrikeoutSite.Stream>> _streams = [];
    private readonly Dictionary<string, List<StrikeoutSite.Stream>> _alternatives = [];

    public static bool IsStrikeout(EventChannel option) => option.Id >= IdBase;

    /// Streams de una opción "Strikeout" de un partido.
    public List<StrikeoutSite.Stream> StreamsFor(EventChannel option) => _streams.GetValueOrDefault(option.Id) ?? [];

    /// Canal reproducible: el HLS se resuelve al abrirlo (los tokens caducan en minutos).
    public Channel? ChannelFor(EventChannel option)
    {
        if (!_streams.TryGetValue(option.Id, out var list) || list.Count == 0) return null;
        // De entrada, uno en español y HD si lo hay.
        var first = list.FirstOrDefault(s => s.Language == "Español" && s.IsHD) ?? list.FirstOrDefault(s => s.IsHD) ?? list[0];
        return ChannelFor(first, list, option.Name);
    }

    /// Canal para un stream concreto; `among` son los que se podrán elegir en el reproductor.
    public Channel ChannelFor(StrikeoutSite.Stream stream, List<StrikeoutSite.Stream> among, string name)
    {
        var ch = new Channel
        {
            Id = "strikeout-" + stream.Path, Name = name, Category = "Strikeout", IsLive = true,
            StreamUrl = stream.Url, PlayerType = Channel.StrikeoutPlayerType,
        };
        _alternatives[ch.Id] = among;
        return ch;
    }

    public List<StrikeoutSite.Stream> Alternatives(Channel channel) =>
        _alternatives.GetValueOrDefault(channel.Id) ?? [];

    private static string? Slug(string? sport) => sport switch
    {
        "Fútbol" => "soccer", "Tenis" => "tennis", "Baloncesto" => "basketball", "Béisbol" => "baseball",
        "Boxeo" => "boxing", "UFC" => "ufc", "Deporte motor" => "formula-1", "Motociclismo" => "motogp",
        _ => null,
    };

    /// Los mismos partidos con los canales de Strikeout añadidos al final.
    public async Task<List<LiveEvent>> AttachAsync(IReadOnlyList<LiveEvent> events, CancellationToken ct = default)
    {
        // Fútbol siempre: la cartelera no siempre trae el deporte.
        var wanted = events.Select(e => Slug(e.Sport)).Where(s => s != null).Append("soccer").ToHashSet();
        var schedules = (await Task.WhenAll(StrikeoutSite.Sports.Where(s => wanted.Contains(s.Slug)).Select(async s =>
        {
            try { return await StrikeoutSite.ScheduleAsync(s, ct); } catch (Exception) { return []; }
        }))).SelectMany(x => x).ToList();

        var matched = new List<(int Index, StrikeoutSite.Event Event)>();
        for (var i = 0; i < events.Count; i++)
        {
            if (events[i].Teams() is not { } t) continue;
            var m = schedules.FirstOrDefault(s => Pairs(s, t.Home, t.Away));
            if (m != null) matched.Add((i, m));
        }

        var found = await Task.WhenAll(matched.Select(async m =>
        {
            // Un reintento: con tantas peticiones a la vez, Strikeout a veces corta alguna.
            try { return (m.Index, List: await StrikeoutSite.StreamsAsync(m.Event, ct)); }
            catch (Exception) when (!ct.IsCancellationRequested) { }
            try
            {
                await Task.Delay(1000, ct);
                return (m.Index, List: await StrikeoutSite.StreamsAsync(m.Event, ct));
            }
            catch (Exception) { return (m.Index, List: []); }
        }));

        var merged = events.Select(e => e with { Channels = [.. e.Channels] }).ToList();
        var nextId = IdBase;
        _streams.Clear();
        foreach (var (index, list) in found.OrderBy(f => f.Index).Where(f => f.List.Count > 0))
        {
            _streams[nextId] = list;
            merged[index].Channels.Add(new EventChannel(nextId, "Strikeout", null));
            nextId++;
        }
        return merged;
    }

    /// "Italy vs. Belgium" ↔ "Bélgica at Italia": los dos equipos, en cualquier orden.
    private static bool Pairs(StrikeoutSite.Event ev, string home, string away)
    {
        var teams = ev.Title.Split(" vs. ");
        if (teams.Length != 2) teams = ev.Title.Split(" vs ");
        if (teams.Length != 2) return false;
        return (Text.SimilarTeam(teams[0], home) && Text.SimilarTeam(teams[1], away))
            || (Text.SimilarTeam(teams[0], away) && Text.SimilarTeam(teams[1], home));
    }
}
