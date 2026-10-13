using KerterCore.Models;
using KerterCore.Strikeout;

namespace KerterCore.Api;

/// Cartelera del día: eventos de Kerter con los streams de Strikeout sumados.
public sealed class EventsService(KerterApi api, AuthService auth)
{
    public StrikeoutChannels Strikeout { get; } = new();
    private List<Channel> _channels = [];

    public async Task<List<LiveEvent>> LoadAsync(CancellationToken ct = default) =>
        await LoadAsync(false, ct);

    private async Task<List<LiveEvent>> LoadAsync(bool renewed, CancellationToken ct)
    {
        try
        {
            _channels = await api.FetchChannelsAsync(ct);
            var assignments = await api.FetchAssignmentsAsync(DateTime.Now.ToString("yyyy-MM-dd"), ct);
            return LiveEvent.Group(assignments);
        }
        catch (ApiException e) when (e.IsUnauthorized)
        {
            // Sesión caducada: se vuelve a entrar sola y se reintenta una vez.
            if (renewed) { auth.ExpireSession(); throw; }
            if (await auth.RenewSessionAsync()) return await LoadAsync(true, ct);
            throw;
        }
    }

    /// Suma los streams de Strikeout (tarda más: va después de pintar la cartelera).
    public Task<List<LiveEvent>> AttachStrikeoutAsync(IReadOnlyList<LiveEvent> events, CancellationToken ct = default) =>
        Strikeout.AttachAsync(events, ct);

    /// Canal reproducible para una opción del selector de un partido.
    public Channel? ChannelFor(EventChannel option) =>
        StrikeoutChannels.IsStrikeout(option)
            ? Strikeout.ChannelFor(option)
            : _channels.FirstOrDefault(c => c.Id == option.Id.ToString());
}
