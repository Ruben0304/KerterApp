using KerterCore.Models;

namespace KerterWin.Services;

/// Una forma de ver el partido (un canal de Kerter o un stream de Strikeout).
public sealed record PlayOption(string Label, Channel Channel);

/// Qué abre el reproductor: el canal elegido y el resto de opciones del partido para cambiar al vuelo.
public sealed record PlayRequest(Channel Channel, string Title, IReadOnlyList<PlayOption> Options);
