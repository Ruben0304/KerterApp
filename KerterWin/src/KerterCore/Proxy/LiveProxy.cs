using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace KerterCore.Proxy;

/// Graba un directo HLS en disco y se lo sirve al reproductor desde el propio
/// equipo (127.0.0.1).
///
/// Por qué: los servidores de los canales solo guardan 14–30 s de directo y
/// un reproductor baja los fragmentos de uno en uno por una sola conexión. Con una
/// conexión que va de buena a muy mala, eso se traduce en cortes y en quedarse
/// fuera de la ventana del servidor (el video se rompe). Aquí:
/// - el grabador baja cada fragmento en cuanto aparece, por varias conexiones
///   (`SegmentFetcher`), y lo guarda en disco, donde no caduca: el margen
///   puede crecer más allá de lo que guarda el servidor, se puede pausar para
///   juntar colchón y rebobinar;
/// - la calidad la decide el grabador, fragmento a fragmento, mirando sobre
///   todo el margen grabado y si se está quedando atrás (la velocidad medida es
///   ruido con esta conexión); baja al momento y sube de uno en uno;
/// - el reproductor solo ve una playlist local con lo grabado: nunca toca internet.
///
/// Todo su estado vive en `queue` (cola serial de un solo hilo).
public sealed class LiveProxy : IDisposable
{
    public sealed record Status(
        // Segundos grabados por delante de lo que se está viendo.
        double BufferAhead,
        int Level,
        int Height,
        // Velocidad estimada de la conexión (bits/s), prudente.
        double? Throughput,
        // Cuánto va el grabador por detrás de lo que publica el servidor.
        double BehindLive,
        // Fragmentos que el servidor borró antes de poder bajarlos.
        int LostSegments,
        // Conexiones recibiendo datos ahora mismo.
        int Transferring,
        // El canal no emite: su servidor publica fragmentos vacíos (fallo en
        // su origen, no de la conexión).
        bool SourceDown);

    sealed record Recorded(int LocalSequence, double Duration, int Level, bool Discontinuity, DateTime Date);

    sealed record Finished(byte[] Data, int Level, double Duration, bool Discontinuity);

    sealed class Ewma
    {
        readonly double halfLife;
        double estimate;
        double weight;
        public Ewma(double halfLife) => this.halfLife = halfLife;

        public void Add(double value, double w)
        {
            var alpha = Math.Pow(0.5, w / halfLife);
            estimate = value * (1 - alpha) + alpha * estimate;
            weight += w;
        }

        public double? Value => weight >= 1 ? estimate / (1 - Math.Pow(0.5, weight / halfLife)) : null;
    }

    // MARK: - API pública

    /// Calidades disponibles, de menor a mayor bitrate. Fijas tras arrancar.
    public IReadOnlyList<Variant> Variants => variants;
    public Uri? LocalUrl { get; private set; }

    /// Origen de la línea de tiempo local: la fecha de la playlist local de un
    /// punto es TimelineOrigin + (tiempo de medios desde el primer fragmento
    /// grabado). Sirve para calcular el `ReportPlayhead` si el reproductor
    /// no expone #EXT-X-PROGRAM-DATE-TIME.
    public DateTime TimelineOrigin => timelineStart;

    /// Se completa cuando el grabador ya se paró y limpió el disco.
    public Task Completion => queue.Completion;

    readonly SerialQueue queue = new();
    readonly Uri source;
    readonly IReadOnlyDictionary<string, string>? headers;
    readonly SegmentFetcher fetcher;
    readonly string directory;
    LocalHttpServer? server;
    Action<Status>? statusHandler;
    Variant[] variants = Array.Empty<Variant>();

    // Estado del grabador (todo en `queue`).
    int level;
    int? manualLevel;
    bool abrEnabled = true;
    int? alignmentCheckFrom;
    readonly Dictionary<int, (Hls.MediaPlaylist Playlist, DateTime At)> playlists = new();
    double targetDuration = 3.0;
    bool independentSegments;
    int? nextSequence;
    int appendCursor;
    readonly Dictionary<int, SegmentFetcher.Job> jobs = new();
    readonly Dictionary<int, Finished> finished = new();
    readonly HashSet<int> skipped = new();
    readonly List<Recorded> recorded = new();
    int firstLocalSequence;
    int evictedDiscontinuities;
    bool gapPending;
    DateTime timelineStart = DateTime.UtcNow;
    DateTime timelineEnd = DateTime.UtcNow;
    readonly Dictionary<int, List<int>> sizes = new();
    readonly Ewma fastRate = new(3);
    readonly Ewma slowRate = new(10);
    double silentFor;
    DateTime? playhead;
    readonly List<(DateTime At, int Lag)> lagHistory = new();
    bool caughtUp;
    readonly DateTime startedAt = DateTime.UtcNow;
    DateTime lastDown = DateTime.MinValue;
    DateTime lastUp = DateTime.MinValue;
    int lost;
    bool pollInFlight;
    int pollId;
    bool pollAgain;
    int pollGeneration;
    int pollFailures;
    DateTime lastPlaylistSuccess = DateTime.UtcNow;
    bool upstreamEnded;
    // Desde cuándo el servidor publica fragmentos vacíos (duración ~0).
    DateTime? brokenSince;
    CancellationTokenSource? timerCts;
    int ticks;
    bool stopped;
    Action<bool>? readyHandler;
    // Cuánto se guarda por detrás de lo que se ve (para rebobinar).
    double keepBehind = 2 * 3600;

    static readonly string Root = Path.Combine(Path.GetTempPath(), "KerterLive");

    /// Una carpeta por canal.
    static string DirectoryFor(Uri source)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(source.AbsoluteUri));
        var key = Convert.ToHexString(digest, 0, 8).ToLowerInvariant();
        return Path.Combine(Root, key);
    }

    string FilePath(int localSequence) => Path.Combine(directory, $"{localSequence}.ts");

    LiveProxy(Uri source, IReadOnlyDictionary<string, string>? headers)
    {
        this.source = source;
        this.headers = headers;
        directory = DirectoryFor(source);
        fetcher = new SegmentFetcher(queue, headers);
    }

    /// Arranca el grabador para `source` y espera a tener los primeros
    /// fragmentos. Devuelve null si el stream no se puede grabar (VOD, cifrado,
    /// fMP4…) o no arranca a tiempo: entonces se reproduce directo del servidor.
    /// `onStatus` recibe el estado cada medio segundo (en un hilo del pool)
    /// desde el arranque: así se puede avisar si el canal no emite.
    /// `headers` se manda en todas las peticiones (playlists y fragmentos).
    public static async Task<LiveProxy?> StartAsync(Uri source, IReadOnlyDictionary<string, string>? headers,
                                                    Action<Status> onStatus, CancellationToken ct = default)
    {
        var proxy = new LiveProxy(source, headers) { statusHandler = onStatus };
        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        // Si quien espera se cancela (se cerró el reproductor), el grabador se
        // para: si no, con un canal caído seguiría esperando para siempre.
        using var registration = ct.Register(proxy.Stop);
        if (!proxy.queue.Post(() => proxy.Boot(ok => tcs.TrySetResult(ok)))) tcs.TrySetResult(false);
        var ok = await tcs.Task.ConfigureAwait(false);
        if (!ok || proxy.server is not { } server)
        {
            proxy.Stop();
            return null;
        }
        proxy.LocalUrl = new Uri($"http://127.0.0.1:{server.Port}/live.m3u8");
        return proxy;
    }

    /// Fecha (de la playlist local) de lo que se está viendo.
    public void ReportPlayhead(DateTime date) => queue.Post(() => playhead = date);

    /// null = automática.
    public void SetManualLevel(int? newLevel) => queue.Post(() =>
    {
        manualLevel = newLevel;
        if (newLevel is { } l && l != level) SwitchLevel(l);
    });

    /// Cambio de red: las conexiones viejas pueden estar muertas sin saberlo.
    public void NetworkChanged(bool online)
    {
        if (!online) return;
        queue.Post(() =>
        {
            ProxyLog.Log(() => "red de vuelta/cambiada → conexiones nuevas");
            fetcher.ResetAll();
            PollNow();
        });
    }

    /// El reproductor lleva rato atascado: rehacer conexiones y releer.
    public void Kick() => queue.Post(() =>
    {
        ProxyLog.Log(() => "reproductor atascado → conexiones nuevas");
        fetcher.ResetAll();
        PollNow();
    });

    /// Deja de descargar y borra lo grabado.
    public void Stop() => queue.Post(() =>
    {
        if (stopped) return;
        stopped = true;
        timerCts?.Cancel();
        fetcher.Invalidate();
        server?.Stop();
        try { Directory.Delete(directory, recursive: true); } catch { }
        if (readyHandler is { } ready)
        {
            readyHandler = null;
            ready(false);
        }
        queue.Complete();
    });

    public void Dispose() => Stop();

    // MARK: - Arranque

    void Boot(Action<bool> completion)
    {
        if (stopped) { completion(false); return; }
        // Siempre arranque en vivo: lo que hubiera de este canal se descarta.
        try
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
            Directory.CreateDirectory(directory);
        }
        catch
        {
            completion(false);
            return;
        }
        readyHandler = completion;
        ArmBootDeadline();
        LoadSource(1);
    }

    /// Plazo de arranque: 25 s. Si el canal no emite (fragmentos vacíos), se
    /// sigue esperando a que vuelva en vez de rendirse.
    void ArmBootDeadline() => queue.PostAfter(25, () =>
    {
        if (readyHandler == null) return;
        if (SourceDown) { ArmBootDeadline(); return; }
        var ready = readyHandler;
        readyHandler = null;
        ProxyLog.Log(() => $"arranque: plazo agotado con {recorded.Count} fragmentos");
        ready(recorded.Count > 0);
    });

    bool SourceDown => brokenSince is { } since && (DateTime.UtcNow - since).TotalSeconds > 2;

    void FinishBoot(bool ok, string? reason = null)
    {
        if (reason != null) ProxyLog.Log(() => $"no se graba: {reason}");
        if (readyHandler is not { } ready) return;
        if (!ok)
        {
            readyHandler = null;
            ready(false);
        }
    }

    void LoadSource(int attempt) => fetcher.FetchText(source, 8, result =>
    {
        if (stopped) return;
        if (!result.Ok)
        {
            if (attempt >= 3) { FinishBoot(false, "no carga la playlist"); return; }
            queue.PostAfter(0.5, () => LoadSource(attempt + 1));
            return;
        }
        switch (Hls.Parse(result.Text!, result.Url))
        {
            case Hls.MasterPlaylist master:
                if (master.Unsupported != null) { FinishBoot(false, master.Unsupported); return; }
                if (master.Variants.Count == 0) { FinishBoot(false, "playlist sin variantes"); return; }
                variants = master.Variants.ToArray();
                // Se arranca en la segunda más baja: la ventana del servidor
                // entra rápido y luego se sube si la conexión lo permite.
                level = variants.Length >= 3 ? 1 : 0;
                LoadFirstMedia(1);
                break;
            case Hls.MediaPlaylist media:
                variants = new[] { new Variant(0, 0, 0, media.Url) };
                level = 0;
                BeginRecording(media);
                break;
            default:
                FinishBoot(false, "playlist ilegible");
                break;
        }
    });

    void LoadFirstMedia(int attempt)
    {
        var requested = level;
        fetcher.FetchText(variants[requested].Url, 8, result =>
        {
            if (stopped) return;
            if (!result.Ok || Hls.Parse(result.Text!, result.Url) is not Hls.MediaPlaylist media)
            {
                if (attempt >= 3) { FinishBoot(false, "no carga la variante"); return; }
                queue.PostAfter(0.5, () => LoadFirstMedia(attempt + 1));
                return;
            }
            BeginRecording(media);
        });
    }

    void BeginRecording(Hls.MediaPlaylist playlist)
    {
        if (playlist.Unsupported != null) { FinishBoot(false, playlist.Unsupported); return; }
        if (playlist.IsEnded) { FinishBoot(false, "no es un directo"); return; }
        if (playlist.Segments.Count == 0) { FinishBoot(false, "playlist vacía"); return; }
        independentSegments = playlist.IndependentSegments;

        if (!StartServer()) { FinishBoot(false, "no abre el servidor local"); return; }
        ProxyLog.Log(() => $"grabando {source} · {variants.Length} calidades · "
                           + $"ventana {(int)(playlist.Segments.Count * playlist.TargetDuration)} s · puerto {server?.Port}");
        if (timerCts == null) StartTimer();
        Ingest(playlist, level);
        SchedulePoll(PollInterval);
    }

    bool StartServer()
    {
        if (server != null) return true;
        var s = new LocalHttpServer(path => queue.Invoke(() => Handle(path)));
        if (!s.Start()) return false;
        server = s;
        return true;
    }

    void StartTimer()
    {
        var cts = new CancellationTokenSource();
        timerCts = cts;
        _ = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(250));
            try
            {
                while (await timer.WaitForNextTickAsync(cts.Token)) queue.Post(Tick);
            }
            catch (OperationCanceledException) { }
        });
    }

    // MARK: - Playlist del servidor

    double PollInterval => Math.Min(2, Math.Max(0.5, targetDuration / 2));

    void SchedulePoll(double delay)
    {
        pollGeneration++;
        var generation = pollGeneration;
        queue.PostAfter(delay, () =>
        {
            if (generation != pollGeneration) return;
            Poll();
        });
    }

    void PollNow()
    {
        if (pollInFlight) pollAgain = true; else Poll();
    }

    void Poll()
    {
        if (stopped || pollInFlight) return;
        pollInFlight = true;
        pollId++;
        var id = pollId;
        var requested = level;
        fetcher.FetchText(variants[requested].Url, 6, result =>
        {
            // Una respuesta de una consulta ya abandonada no cuenta.
            if (stopped || id != pollId) return;
            pollInFlight = false;
            if (result.Ok && Hls.Parse(result.Text!, result.Url) is Hls.MediaPlaylist playlist)
            {
                pollFailures = 0;
                Ingest(playlist, requested);
            }
            else
            {
                pollFailures++;
                if (pollFailures == 2) fetcher.RenewPlaylistConnection();
            }
            if (pollAgain)
            {
                pollAgain = false;
                Poll();
            }
            else if (!upstreamEnded)
            {
                SchedulePoll(pollFailures > 0 ? Math.Min(2, 0.5 * pollFailures) : PollInterval);
            }
        });
    }

    void Ingest(Hls.MediaPlaylist playlist, int fetchedLevel)
    {
        lastPlaylistSuccess = DateTime.UtcNow;
        playlists[fetchedLevel] = (playlist, DateTime.UtcNow);
        if (fetchedLevel != level) return;
        targetDuration = playlist.TargetDuration;

        // Fragmentos de duración ~0 sin imagen: el codificador del canal falla.
        var empty = playlist.Segments.Count(s => s.Duration < 0.1);
        if (playlist.Segments.Count > 0 && empty * 2 >= playlist.Segments.Count)
        {
            if (brokenSince == null) ProxyLog.Log(() => "el canal publica fragmentos vacíos: su señal de origen está caída");
            brokenSince ??= DateTime.UtcNow;
        }
        else if (brokenSince != null)
        {
            ProxyLog.Log(() => "el canal vuelve a emitir");
            brokenSince = null;
        }

        if (alignmentCheckFrom is { } previous)
        {
            alignmentCheckFrom = null;
            if (Alignment(playlist, fetchedLevel) == false)
            {
                ProxyLog.Log(() => "las calidades no van sincronizadas → calidad fija");
                abrEnabled = false;
                manualLevel = null;
                level = previous;
                PollNow();
                return;
            }
        }

        if (nextSequence == null)
        {
            // Desde lo más antiguo que guarda el servidor (más margen de
            // entrada), menos el primero, que puede desaparecer mientras baja.
            var first = playlist.Segments.Count >= 4 ? playlist.FirstSequence + 1 : playlist.FirstSequence;
            nextSequence = first;
            appendCursor = first;
        }
        var next = nextSequence.Value;

        // El stream se reinició (la numeración vuelve atrás): se empieza de nuevo.
        if (playlist.LastSequence + 3 < appendCursor)
        {
            ProxyLog.Log(() => "el servidor reinició la numeración → se continúa desde su inicio");
            foreach (var job in jobs.Values.ToList()) fetcher.Cancel(job);
            jobs.Clear();
            finished.Clear();
            skipped.Clear();
            next = playlist.FirstSequence;
            appendCursor = next;
            gapPending = true;
        }
        // Lo que el servidor ya borró sin que llegáramos a pedirlo.
        if (next < playlist.FirstSequence)
        {
            var missing = Enumerable.Range(next, playlist.FirstSequence - next)
                .Where(s => !jobs.ContainsKey(s) && !finished.ContainsKey(s)).ToList();
            skipped.UnionWith(missing);
            // Con el canal caído son fragmentos vacíos: no se pierde nada.
            if (missing.Count > 0 && brokenSince == null)
            {
                lost += missing.Count;
                ProxyLog.Log(() => $"perdidos {missing.Count} fragmentos (el servidor ya los borró)");
            }
            next = playlist.FirstSequence;
        }
        nextSequence = next;
        upstreamEnded = playlist.IsEnded;
        AppendInOrder();
        Schedule();
    }

    /// ¿Van las calidades sincronizadas (mismos números de fragmento con la
    /// misma duración)? Se compara con la playlist más reciente de otra
    /// calidad; null si no hay fragmentos en común con los que comparar (solo
    /// se desactiva el cambio de calidad con pruebas de que no cuadran).
    bool? Alignment(Hls.MediaPlaylist @new, int forLevel)
    {
        var others = playlists.Where(p => p.Key != forLevel).ToList();
        if (others.Count == 0) return null;
        var old = others.MaxBy(p => p.Value.At).Value.Playlist;
        var lower = Math.Max(@new.FirstSequence, old.FirstSequence);
        var upper = Math.Min(@new.LastSequence, old.LastSequence);
        if (lower > upper) return null;
        for (var sequence = lower; sequence <= upper; sequence++)
        {
            if (@new.Segment(sequence) is not { } a || old.Segment(sequence) is not { } b) return false;
            if (Math.Abs(a.Duration - b.Duration) >= 0.1) return false;
        }
        return true;
    }

    // MARK: - Descargas

    void Schedule()
    {
        if (stopped) return;
        var skippedEmpty = false;
        try
        {
            while (fetcher.IdleLaneCount > 0 && jobs.Count < fetcher.LaneCount && nextSequence is { } next)
            {
                var wanted = ChooseLevel();
                if (wanted != level) SwitchLevel(wanted);
                if (alignmentCheckFrom != null) break;
                if (!playlists.TryGetValue(level, out var entry)) break;
                if ((DateTime.UtcNow - entry.At).TotalSeconds >= Math.Max(6, 3 * targetDuration)) break;
                if (entry.Playlist.Segment(next) is not { } segment) break;
                var playlist = entry.Playlist;

                // Duración ~0: sin imagen que mostrar (canal con la señal caída).
                if (segment.Duration < 0.05)
                {
                    skipped.Add(next);
                    nextSequence = next + 1;
                    skippedEmpty = true;
                    continue;
                }

                var chosen = level;
                // Si no hay nada más pendiente, el fragmento se parte entre las
                // conexiones libres; si hay varios, va uno por conexión.
                var alone = playlist.LastSequence == next && jobs.Count == 0;
                var job = fetcher.Fetch(next, segment.Url, EstimatedSize(chosen, segment.Duration), alone,
                                        result => JobFinished(next, chosen, segment, result));
                jobs[next] = job;
                nextSequence = next + 1;
            }
        }
        finally
        {
            if (skippedEmpty) AppendInOrder();
        }
    }

    int? EstimatedSize(int forLevel, double duration)
    {
        if (sizes.TryGetValue(forLevel, out var recent) && recent.Count > 0)
            return recent.OrderBy(x => x).ToList()[recent.Count / 2];
        var bandwidth = variants[forLevel].Bandwidth;
        return bandwidth > 0 ? (int)(bandwidth * duration / 8 * 0.8) : null;
    }

    void JobFinished(int sequence, int forLevel, Hls.Segment segment, SegmentFetcher.FetchResult result)
    {
        if (stopped || !jobs.Remove(sequence)) return;
        if (result.Ok)
        {
            finished[sequence] = new Finished(result.Data!, forLevel, segment.Duration, segment.Discontinuity);
            if (!sizes.TryGetValue(forLevel, out var list)) sizes[forLevel] = list = new List<int>();
            list.Add(result.Data!.Length);
            if (list.Count > 8) list.RemoveAt(0);
        }
        else if (result.Failure.Kind == SegmentFetcher.FailureKind.Cancelled)
        {
            return;
        }
        else
        {
            ProxyLog.Log(() => $"seg {sequence} perdido: {result.Failure}");
            skipped.Add(sequence);
            lost++;
        }
        AppendInOrder();
        Schedule();
    }

    // MARK: - Grabación

    void AppendInOrder()
    {
        while (true)
        {
            if (finished.Remove(appendCursor, out var segment)) Append(segment);
            else if (skipped.Remove(appendCursor)) gapPending = true;
            else break;
            appendCursor++;
        }
        EvictOld();
        CheckReady();
    }

    void Append(Finished segment)
    {
        var local = firstLocalSequence + recorded.Count;
        try
        {
            File.WriteAllBytes(FilePath(local), segment.Data);
        }
        catch (Exception e)
        {
            ProxyLog.Log(() => $"no se pudo guardar un fragmento: {e.Message}");
            gapPending = true;
            return;
        }
        if (recorded.Count == 0) timelineStart = timelineEnd;
        var discontinuity = recorded.Count > 0
            && (gapPending || segment.Discontinuity || recorded[^1].Level != segment.Level);
        recorded.Add(new Recorded(local, segment.Duration, segment.Level, discontinuity, timelineEnd));
        timelineEnd = timelineEnd.AddSeconds(segment.Duration);
        gapPending = false;
    }

    void EvictOld()
    {
        // Hasta que se reproduce algo no se borra nada.
        if (playhead is not { } head) return;
        var limit = head.AddSeconds(-keepBehind);
        var removed = 0;
        while (recorded.Count - removed > 1)
        {
            var first = recorded[removed];
            if (first.Date.AddSeconds(first.Duration) >= limit) break;
            try { File.Delete(FilePath(first.LocalSequence)); } catch { }
            if (first.Discontinuity) evictedDiscontinuities++;
            removed++;
        }
        if (removed > 0)
        {
            recorded.RemoveRange(0, removed);
            firstLocalSequence += removed;
        }
    }

    void CheckReady()
    {
        if (readyHandler is not { } ready) return;
        // Tres fragmentos dan para arrancar sin atascarse; con la conexión
        // muy mala, se arranca con lo que haya a los 8 s.
        if (recorded.Count >= 3 || (recorded.Count > 0 && (DateTime.UtcNow - startedAt).TotalSeconds > 8))
        {
            readyHandler = null;
            ready(true);
        }
    }

    double BufferAhead
    {
        get
        {
            if (recorded.Count == 0) return 0;
            var from = playhead ?? timelineStart;
            return Math.Max(0, (timelineEnd - from).TotalSeconds);
        }
    }

    // MARK: - Calidad

    /// Fragmentos que el servidor ya publicó y aún no están grabados.
    int LagSegments =>
        playlists.TryGetValue(level, out var entry) ? Math.Max(0, entry.Playlist.LastSequence + 1 - appendCursor) : 0;

    double? Throughput =>
        fastRate.Value is { } fast && slowRate.Value is { } slow ? Math.Min(fast, slow) : null;

    /// La playlist del servidor responde con normalidad (si no, "al día"
    /// puede ser mentira: simplemente no nos enteramos de lo nuevo).
    bool ServerReachable =>
        pollFailures == 0 && (DateTime.UtcNow - lastPlaylistSuccess).TotalSeconds < Math.Max(4, 2 * targetDuration);

    /// El grabador pierde terreno: más pendiente que hace unos segundos.
    bool FallingBehind
    {
        get
        {
            var lag = LagSegments;
            if (lag < 3) return false;
            var reference = DateTime.UtcNow.AddSeconds(-Math.Max(4, 2 * targetDuration));
            var index = lagHistory.FindLastIndex(h => h.At <= reference);
            return index >= 0 && lag > lagHistory[index].Lag;
        }
    }

    /// Margen que se puede tener viendo en directo sin pausar: lo que guarda
    /// el servidor (se entra por su segundo fragmento). Con canales de ventana
    /// corta (20–25 s), umbrales fijos de 15–20 s dejarían la calidad clavada
    /// abajo o subiendo y bajando sin parar.
    double ReachableBuffer
    {
        get
        {
            if (!playlists.TryGetValue(level, out var entry) || entry.Playlist.Segments.Count <= 1) return 30;
            return entry.Playlist.Segments.Skip(1).Sum(s => s.Duration);
        }
    }

    /// Calidad para el siguiente fragmento. Lo principal es no cortarse: el
    /// margen grabado manda y la velocidad solo pone techo.
    int ChooseLevel()
    {
        if (manualLevel is { } manual) return manual;
        var top = variants.Length - 1;
        if (top <= 0 || !abrEnabled || !caughtUp) return level;

        var now = DateTime.UtcNow;
        var buffer = BufferAhead;
        var slack = (nextSequence ?? 0) - (playlists.TryGetValue(level, out var e) ? e.Playlist.FirstSequence : 0);
        var reachable = ReachableBuffer;
        var panic = Math.Min(8, 0.3 * reachable);
        var low = Math.Min(15, 0.5 * reachable);
        var comfortable = Math.Min(20, 0.7 * reachable);
        var lag = LagSegments;

        // 1. Pánico: casi sin margen, o el próximo fragmento está a punto de
        //    desaparecer del servidor → la más ligera, ya.
        if (buffer < panic || (slack <= 1 && lag >= 3)) return 0;

        var estimate = Throughput;
        int? sustainable = null;
        if (estimate is { } r)
        {
            var idx = -1;
            for (var i = 0; i < variants.Length; i++) if (variants[i].Bandwidth <= r * 0.7) idx = i;
            sustainable = Math.Max(0, idx);
        }
        var next = level;

        if (FallingBehind && (now - lastDown).TotalSeconds > targetDuration)
        {
            // 2. El grabador se atrasa: al menos un escalón abajo.
            next = Math.Min(level - 1, sustainable ?? level - 1);
        }
        else if (estimate is { } rate && rate < variants[level].Bandwidth && sustainable is { } sus
                 && (buffer < comfortable || lag >= 2))
        {
            // 3. La conexión ya no da ni para la calidad actual y el margen no
            //    sobra. Con margen de sobra y al día, un bajón de unos segundos
            //    lo absorbe lo grabado: bajar ahí solo hace que la imagen suba
            //    y baje sin necesidad. Con margen justo se baja de uno en uno.
            next = buffer < low ? Math.Min(level, sus) : Math.Max(level - 1, Math.Min(level, sus));
        }
        else if (level < top && lag <= 1 && buffer >= comfortable && ServerReachable
                 && (now - lastDown).TotalSeconds >= 20
                 && (now - lastUp).TotalSeconds >= Math.Max(8, 2 * targetDuration)
                 && sustainable is { } up && up > level)
        {
            // 4. Subir: al día con el directo, con margen y velocidad de sobra.
            //    Hasta dos escalones si la velocidad da para ello.
            next = Math.Min(up, level + 2);
        }
        // 5. Con poco margen, techo en la segunda más baja.
        if (buffer < low) next = Math.Min(next, 1);
        return Math.Max(0, Math.Min(top, next));
    }

    void SwitchLevel(int newLevel)
    {
        if (newLevel < 0 || newLevel >= variants.Length || newLevel == level) return;
        var now = DateTime.UtcNow;
        if (newLevel < level) lastDown = now; else lastUp = now;
        ProxyLog.Log(() => $"calidad {variants[level].Height}p → {variants[newLevel].Height}p · margen {(int)BufferAhead} s · "
                           + $"velocidad {(Throughput is { } t ? (t / 1e6).ToString("F2", CultureInfo.InvariantCulture) : "?")} Mbps · atraso {LagSegments}");
        var previous = level;
        level = newLevel;
        if (playlists.TryGetValue(newLevel, out var cached) && (now - cached.At).TotalSeconds < targetDuration)
        {
            if (Alignment(cached.Playlist, newLevel) == false)
            {
                ProxyLog.Log(() => "las calidades no van sincronizadas → calidad fija");
                abrEnabled = false;
                manualLevel = null;
                level = previous;
            }
        }
        else
        {
            // Hasta tener su playlist no se pide nada de la calidad nueva.
            alignmentCheckFrom = previous;
            PollNow();
        }
    }

    // MARK: - Reloj

    void Tick()
    {
        if (stopped) return;
        var now = DateTime.UtcNow;
        ticks++;

        // Velocidad: bytes entre el tiempo que de verdad se estuvo recibiendo
        // (con fragmentos pequeños, dividir por el tick entero la infravalora).
        // Pedir y no recibir nada durante más de lo que tarda un servidor en
        // contestar cuenta como cero: así un corte real hace bajar la estimación.
        var stats = fetcher.TakeTransferStats();
        silentFor = stats.Bytes > 0 || fetcher.ActiveCount == 0 ? 0 : silentFor + 0.25;
        if (stats.Busy > 0.02)
        {
            var bits = stats.MeasuredBytes * 8.0 / stats.Busy;
            fastRate.Add(bits, stats.Busy);
            slowRate.Add(bits, stats.Busy);
        }
        else if (silentFor > 1.5 && fetcher.TransferringCount == 0)
        {
            // (Un parón a media descarga ya cuenta solo: su hueco entra en `busy`.)
            fastRate.Add(0, 0.25);
            slowRate.Add(0, 0.25);
        }
        fetcher.Watchdog(now, Math.Max(2, targetDuration * 0.6));

        lagHistory.Add((now, LagSegments));
        lagHistory.RemoveAll(h => (now - h.At).TotalSeconds > 20);
        if (!caughtUp && (LagSegments <= 1 || (now - startedAt).TotalSeconds > 30))
        {
            caughtUp = true;
            ProxyLog.Log(() => $"al día con el directo · margen {(int)BufferAhead} s");
        }

        // Sin noticias de la playlist: la conexión de listas puede estar muerta.
        if ((now - lastPlaylistSuccess).TotalSeconds > Math.Max(8, 3 * targetDuration))
        {
            lastPlaylistSuccess = now;
            ProxyLog.Log(() => "playlist sin responder → conexión nueva");
            fetcher.RenewPlaylistConnection();
            pollInFlight = false;
            pollId++;
            Poll();
        }

        if (ticks % 2 == 0) PublishStatus();
        if (ticks % 240 == 1) CheckDiskSpace();
        CheckReady();
        Schedule();
    }

    void PublishStatus()
    {
        var handler = statusHandler;
        if (handler == null) return;
        var height = level >= 0 && level < variants.Length ? variants[level].Height : 0;
        var status = new Status(BufferAhead, level, height, Throughput, LagSegments * targetDuration,
                                lost, fetcher.TransferringCount, SourceDown);
        _ = Task.Run(() => { try { handler(status); } catch { } });
    }

    void CheckDiskSpace()
    {
        try
        {
            var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(directory))!).AvailableFreeSpace;
            // Con el disco casi lleno, solo 15 min para rebobinar.
            keepBehind = free < 3_000_000_000 ? 15 * 60 : 2 * 3600;
        }
        catch { }
    }

    // MARK: - Servidor local

    LocalHttpServer.Response? Handle(string path)
    {
        if (path == "/live.m3u8")
            return new LocalHttpServer.Response("application/vnd.apple.mpegurl", Encoding.UTF8.GetBytes(PlaylistText()));
        const string prefix = "/seg/", suffix = ".ts";
        if (!path.StartsWith(prefix, StringComparison.Ordinal) || !path.EndsWith(suffix, StringComparison.Ordinal)
            || !int.TryParse(path.AsSpan(prefix.Length, path.Length - prefix.Length - suffix.Length),
                             NumberStyles.Integer, CultureInfo.InvariantCulture, out var sequence))
            return null;
        var index = sequence - firstLocalSequence;
        if (index < 0 || index >= recorded.Count) return null;
        try
        {
            return new LocalHttpServer.Response("video/mp2t", File.ReadAllBytes(FilePath(recorded[index].LocalSequence)));
        }
        catch
        {
            return null;
        }
    }

    static string Iso(DateTime date) =>
        date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    string PlaylistText()
    {
        var maxDuration = recorded.Count > 0 ? recorded.Max(r => r.Duration) : targetDuration;
        var first = recorded.Count > 0 ? recorded[0] : null;
        var lines = new List<string>
        {
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            $"#EXT-X-TARGETDURATION:{(int)Math.Ceiling(Math.Max(targetDuration, maxDuration))}",
            $"#EXT-X-MEDIA-SEQUENCE:{firstLocalSequence}",
            // La etiqueta del primero no se escribe pero cuenta, así el número
            // de cada tramo no cambia al ir borrando por delante.
            $"#EXT-X-DISCONTINUITY-SEQUENCE:{evictedDiscontinuities + (first?.Discontinuity == true ? 1 : 0)}",
        };
        if (independentSegments) lines.Add("#EXT-X-INDEPENDENT-SEGMENTS");
        for (var index = 0; index < recorded.Count; index++)
        {
            var segment = recorded[index];
            if (index > 0 && segment.Discontinuity) lines.Add("#EXT-X-DISCONTINUITY");
            // Fecha propia (continua) para que el reproductor nos diga qué está viendo.
            if (index == 0 || segment.Discontinuity) lines.Add($"#EXT-X-PROGRAM-DATE-TIME:{Iso(segment.Date)}");
            lines.Add($"#EXTINF:{segment.Duration.ToString("F3", CultureInfo.InvariantCulture)},");
            lines.Add($"/seg/{segment.LocalSequence}.ts");
        }
        if (upstreamEnded && jobs.Count == 0 && playlists.TryGetValue(level, out var entry)
            && (nextSequence ?? 0) > entry.Playlist.LastSequence)
            lines.Add("#EXT-X-ENDLIST");
        return string.Join("\n", lines) + "\n";
    }
}
