using System.Net;
using System.Net.Http;

namespace KerterCore.Proxy;

/// Descarga de fragmentos por varias conexiones independientes ("carriles").
///
/// Cada carril es su propio HttpClient y por tanto su propia conexión TCP.
/// Con HTTP/2 todo lo de un cliente iría por una sola conexión, y ahí un paquete
/// perdido frena todas las descargas a la vez; con carriles separados, una
/// pérdida solo frena a uno. Además:
/// - un fragmento puede partirse en trozos (`Range`) entre carriles libres;
/// - un trozo que se queda sin recibir datos abandona su conexión (que
///   probablemente esté muerta sin saberlo) y sigue por otra desde el byte
///   donde iba;
/// - si un trozo se atrasa y hay un carril libre, se pide también por ahí y
///   gana el primero que termine (petición de respaldo).
///
/// Todo corre en la cola del grabador (`queue`): sin candados. Las tareas de red
/// solo avisan a la cola.
internal sealed class SegmentFetcher
{
    public enum FailureKind { NotFound, Http, Cancelled }

    public readonly record struct Failure(FailureKind Kind, int Status = 0)
    {
        public override string ToString() => Kind == FailureKind.Http ? $"http({Status})" : Kind.ToString();
    }

    public readonly record struct FetchResult(byte[]? Data, Failure Failure)
    {
        public bool Ok => Data != null;
    }

    public readonly record struct TextResult(string? Text, Uri Url, Exception? Error)
    {
        public bool Ok => Text != null;
    }

    public sealed class Job
    {
        public int Sequence { get; }
        public Uri Url { get; }
        internal List<Piece> Pieces = new();
        internal int? Total;
        internal bool Finished;
        internal Action<FetchResult> Completion;

        internal Job(int sequence, Uri url, Action<FetchResult> completion)
        {
            Sequence = sequence;
            Url = url;
            Completion = completion;
        }
    }

    /// Datos de un trozo: siempre cubren `Start ..< Start + Count`.
    internal sealed class Buffer
    {
        byte[] bytes = new byte[64 * 1024];
        public int Count { get; private set; }
        public bool IsEmpty => Count == 0;

        public void Append(ReadOnlySpan<byte> chunk)
        {
            if (Count + chunk.Length > bytes.Length) Array.Resize(ref bytes, Math.Max(bytes.Length * 2, Count + chunk.Length));
            chunk.CopyTo(bytes.AsSpan(Count));
            Count += chunk.Length;
        }

        public void Truncate(int length) => Count = Math.Min(Count, Math.Max(0, length));
        public ReadOnlySpan<byte> Span => bytes.AsSpan(0, Count);
    }

    /// Un rango de bytes de un fragmento.
    internal sealed class Piece
    {
        public readonly Job Job;
        public readonly int Start;
        public int? End;               // inclusivo; null = hasta el final
        internal readonly Buffer Data = new();
        public Request? Request;
        public Lane? Lane;
        public DateTime ReadyAt = DateTime.MinValue;
        public DateTime RequestedAt = DateTime.UtcNow;
        public DateTime? FirstByteAt;
        public DateTime? LastByteAt;
        public bool Done;
        public int Attempts;
        public int NotFound;
        public Piece? Hedge;           // su petición de respaldo
        public Piece? HedgeOf;         // si esta es el respaldo de otra

        public Piece(Job job, int start, int? end)
        {
            Job = job;
            Start = start;
            End = end;
        }

        public int NextOffset => Start + Data.Count;
        public int? Remaining => End is { } e ? Math.Max(0, e - NextOffset + 1) : null;
    }

    /// Una petición HTTP en vuelo (equivale a la URLSessionDataTask).
    internal sealed class Request
    {
        public readonly CancellationTokenSource Cts = new();
    }

    internal sealed class Lane
    {
        public HttpClient Client;
        public Piece? Piece;
        public Lane(HttpClient client) => Client = client;
    }

    /// Trozos más pequeños no compensan el viaje de ida y vuelta de pedirlos.
    public const int MinPiece = 128 * 1024;
    public const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KerterApp";

    public int LaneCount { get; }
    readonly SerialQueue queue;
    readonly IReadOnlyDictionary<string, string>? headers;
    readonly List<Lane> lanes = new();
    HttpClient playlistClient;
    CancellationTokenSource playlistCts = new();
    readonly Dictionary<Request, Piece> active = new();
    List<Piece> waiting = new();
    int receivedBytes;
    // Bytes y tiempo con alguna conexión recibiendo, para medir la velocidad
    // real: sin los ratos en que no hay nada que bajar ni la espera hasta el
    // primer byte de cada ráfaga (que no depende del ancho de banda).
    int measuredBytes;
    double busyTime;
    DateTime? lastDataAt;
    bool invalidated;
    /// El servidor ignora `Range`: nada de trozos ni respaldos.
    public bool RangesUnsupported { get; private set; }

    public SegmentFetcher(SerialQueue queue, IReadOnlyDictionary<string, string>? headers, int laneCount = 3)
    {
        this.queue = queue;
        this.headers = headers;
        LaneCount = laneCount;
        for (var i = 0; i < laneCount; i++) lanes.Add(new Lane(MakeClient()));
        playlistClient = MakeClient();
    }

    static HttpClient MakeClient() => new(new SocketsHttpHandler
    {
        MaxConnectionsPerServer = 2,
        AutomaticDecompression = DecompressionMethods.None,
        UseCookies = false,
        AllowAutoRedirect = true,
        ConnectTimeout = TimeSpan.FromSeconds(10),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
    }, disposeHandler: true)
    { Timeout = Timeout.InfiniteTimeSpan };

    HttpRequestMessage NewRequest(Uri url)
    {
        var message = new HttpRequestMessage(HttpMethod.Get, url);
        message.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        if (headers != null)
            foreach (var (key, value) in headers)
            {
                message.Headers.Remove(key);
                message.Headers.TryAddWithoutValidation(key, value);
            }
        return message;
    }

    // MARK: - API (siempre desde `queue`)

    /// Carriles libres que no están reservados para reintentos pendientes.
    public int IdleLaneCount => Math.Max(0, lanes.Count(l => l.Piece == null) - waiting.Count);

    /// Trozos pedidos (con o sin datos aún).
    public int ActiveCount => active.Count;

    /// Carriles recibiendo datos ahora mismo.
    public int TransferringCount => active.Values.Count(p => p.FirstByteAt != null && !p.Done);

    /// Desde la última llamada: bytes recibidos y, para medir la velocidad,
    /// los bytes y el tiempo de las ráfagas de descarga.
    public (int Bytes, int MeasuredBytes, double Busy) TakeTransferStats()
    {
        var result = (receivedBytes, measuredBytes, busyTime);
        receivedBytes = 0;
        measuredBytes = 0;
        busyTime = 0;
        return result;
    }

    /// Baja un fragmento. Si `allowSplit` y se espera grande, se parte entre
    /// los carriles libres: el último trozo va abierto (`bytes=N-`), así que
    /// aunque la estimación falle no se baja nada de más.
    public Job Fetch(int sequence, Uri url, int? estimatedSize, bool allowSplit, Action<FetchResult> completion)
    {
        var job = new Job(sequence, url, completion);
        var count = 1;
        if (allowSplit && !RangesUnsupported && estimatedSize is { } size)
            count = Math.Max(1, Math.Min(Math.Min(IdleLaneCount, 3), size / MinPiece));
        if (count > 1 && estimatedSize is { } total)
        {
            var bounds = Enumerable.Range(0, count).Select(i => (int)((long)total * i / count)).ToArray();
            for (var i = 0; i < count; i++)
                job.Pieces.Add(new Piece(job, bounds[i], i + 1 < count ? bounds[i + 1] - 1 : null));
        }
        else
        {
            job.Pieces.Add(new Piece(job, 0, null));
        }
        waiting.AddRange(job.Pieces);
        Dispatch();
        return job;
    }

    public void Cancel(Job job) => Fail(job, new Failure(FailureKind.Cancelled));

    /// Texto (playlists) por una conexión aparte: enterarse de un fragmento
    /// nuevo no espera a que acabe una descarga pesada.
    public void FetchText(Uri url, double timeout, Action<TextResult> completion)
    {
        var client = playlistClient;
        var cts = CancellationTokenSource.CreateLinkedTokenSource(playlistCts.Token);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout));
        _ = Task.Run(async () =>
        {
            TextResult result;
            try
            {
                using var message = NewRequest(url);
                using var response = await client.SendAsync(message, HttpCompletionOption.ResponseContentRead, cts.Token);
                if (!response.IsSuccessStatusCode)
                    result = new TextResult(null, url, new HttpRequestException($"HTTP {(int)response.StatusCode}"));
                else
                {
                    var bytes = await response.Content.ReadAsByteArrayAsync(cts.Token);
                    result = new TextResult(System.Text.Encoding.UTF8.GetString(bytes),
                                            response.RequestMessage?.RequestUri ?? url, null);
                }
            }
            catch (Exception e)
            {
                result = new TextResult(null, url, e);
            }
            finally
            {
                cts.Dispose();
            }
            queue.Post(() => completion(result));
        });
    }

    public void RenewPlaylistConnection()
    {
        playlistCts.Cancel();
        playlistClient.Dispose();
        playlistCts = new CancellationTokenSource();
        playlistClient = MakeClient();
    }

    /// Cambio de red o atasco general: todas las conexiones viejas pueden
    /// estar muertas sin saberlo. Se rehacen y cada trozo sigue donde iba.
    public void ResetAll()
    {
        foreach (var piece in active.Values.ToList()) Abandon(piece, renewConnection: false);
        foreach (var lane in lanes) Renew(lane);
        RenewPlaylistConnection();
        Dispatch();
    }

    public void Invalidate()
    {
        invalidated = true;
        foreach (var piece in active.Values.ToList()) Detach(piece);
        waiting.Clear();
        foreach (var lane in lanes) lane.Client.Dispose();
        playlistCts.Cancel();
        playlistClient.Dispose();
    }

    /// Vigilancia periódica: conexiones mudas y peticiones de respaldo.
    public void Watchdog(DateTime now, double hedgeAfter)
    {
        foreach (var piece in active.Values.ToList())
        {
            var silence = (now - (piece.LastByteAt ?? piece.RequestedAt)).TotalSeconds;
            // Antes del primer byte se tolera más (latencia del servidor).
            if (silence > (piece.FirstByteAt == null ? 4 : 3))
            {
                ProxyLog.Log(() => $"seg {piece.Job.Sequence} [{piece.Start}-]: {(int)silence} s sin datos → conexión nueva");
                Abandon(piece, renewConnection: true);
            }
        }
        if (!RangesUnsupported && IdleLaneCount > 0)
        {
            var late = active.Values.Where(p => p.Hedge == null && p.HedgeOf == null && !p.Done
                                                && (now - p.RequestedAt).TotalSeconds > hedgeAfter
                                                && (p.Remaining ?? int.MaxValue) > 24 * 1024);
            var chosen = late.OrderBy(p => p.Job.Sequence).ThenBy(p => p.Start).FirstOrDefault();
            if (chosen != null)
            {
                var hedge = new Piece(chosen.Job, chosen.NextOffset, chosen.End) { HedgeOf = chosen };
                chosen.Hedge = hedge;
                chosen.Job.Pieces.Add(hedge);
                waiting.Add(hedge);
                ProxyLog.Log(() => $"seg {chosen.Job.Sequence}: va lento → respaldo desde el byte {hedge.Start}");
            }
        }
        Dispatch();
    }

    // MARK: - Reparto

    void Dispatch()
    {
        if (invalidated) return;
        var now = DateTime.UtcNow;
        waiting.RemoveAll(p => p.Job.Finished);
        waiting = waiting.OrderBy(p => p.Job.Sequence).ThenBy(p => p.Start).ToList();
        foreach (var lane in lanes)
        {
            if (lane.Piece != null) continue;
            var index = waiting.FindIndex(p => p.ReadyAt <= now);
            if (index < 0) break;
            var piece = waiting[index];
            waiting.RemoveAt(index);
            Start(piece, lane);
        }
    }

    void Start(Piece piece, Lane lane)
    {
        var request = new Request();
        piece.Request = request;
        piece.Lane = lane;
        piece.RequestedAt = DateTime.UtcNow;
        piece.FirstByteAt = null;
        piece.LastByteAt = null;
        lane.Piece = piece;
        active[request] = piece;
        var range = piece.Start > 0 || piece.End != null
            ? $"bytes={piece.Start}-{(piece.End?.ToString() ?? "")}" : null;
        _ = Run(request, lane.Client, piece.Job.Url, range);
    }

    /// Hilo de red de una petición: solo avisa a la cola de lo que ocurre.
    async Task Run(Request request, HttpClient client, Uri url, string? range)
    {
        var token = request.Cts.Token;
        try
        {
            using var message = NewRequest(url);
            if (range != null) message.Headers.TryAddWithoutValidation("Range", range);
            using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, token);
            var status = (int)response.StatusCode;
            long? contentLength = response.Content.Headers.ContentLength;
            long? rangeTotal = response.Content.Headers.ContentRange?.Length;
            var decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!queue.Post(() => decision.TrySetResult(OnResponse(request, status, contentLength, rangeTotal))))
                return;
            if (!await decision.Task.WaitAsync(token)) return;

            using var stream = await response.Content.ReadAsStreamAsync(token);
            var buffer = new byte[32 * 1024];
            while (true)
            {
                var n = await stream.ReadAsync(buffer, token);
                if (n == 0) break;
                var chunk = buffer.AsSpan(0, n).ToArray();
                queue.Post(() => OnData(request, chunk));
            }
            queue.Post(() => OnComplete(request, null));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            // Soltada a propósito (Detach): la cola ya lo sabe.
        }
        catch (Exception e)
        {
            queue.Post(() => OnComplete(request, e));
        }
    }

    void Requeue(Piece piece, double delay)
    {
        piece.ReadyAt = DateTime.UtcNow.AddSeconds(delay);
        waiting.Add(piece);
        if (delay > 0) queue.PostAfter(delay + 0.01, Dispatch);
    }

    static double Backoff(int attempts) => Math.Min(2, 0.15 * Math.Pow(2, Math.Max(0, attempts - 1)));

    void Renew(Lane lane)
    {
        lane.Client.Dispose();
        lane.Client = MakeClient();
    }

    /// Suelta el trozo de su petición y su carril (sin tocar sus datos).
    void Detach(Piece piece)
    {
        if (piece.Request is { } request)
        {
            active.Remove(request);
            try { request.Cts.Cancel(); } catch (ObjectDisposedException) { }
        }
        piece.Request = null;
        if (piece.Lane is { } lane && ReferenceEquals(lane.Piece, piece)) lane.Piece = null;
        piece.Lane = null;
        // Fin de la ráfaga: lo que tarde en llegar el siguiente primer byte no cuenta.
        if (!active.Values.Any(p => p.FirstByteAt != null)) lastDataAt = null;
    }

    /// El trozo se cortó o se quedó mudo: lo que falta se pide otra vez.
    void Abandon(Piece piece, bool renewConnection)
    {
        var lane = piece.Lane;
        Detach(piece);
        if (renewConnection && lane != null) Renew(lane);
        piece.Attempts++;
        var job = piece.Job;

        if (piece.HedgeOf is { } original)
        {
            // Un respaldo que falla se descarta: el original sigue.
            original.Hedge = null;
            job.Pieces.Remove(piece);
        }
        else if (piece.Hedge is { Done: false } hedge)
        {
            // El original falla con un respaldo en marcha: se queda con lo que
            // tenía hasta donde empieza el respaldo, que sigue solo.
            piece.Data.Truncate(hedge.Start - piece.Start);
            piece.End = hedge.Start - 1;
            piece.Done = true;
            piece.Hedge = null;
            hedge.HedgeOf = null;
        }
        else if (piece.Data.IsEmpty)
        {
            Requeue(piece, Backoff(piece.Attempts));
        }
        else
        {
            var rest = new Piece(job, piece.NextOffset, piece.End) { Attempts = piece.Attempts };
            piece.End = piece.NextOffset - 1;
            piece.Done = true;
            job.Pieces.Add(rest);
            Requeue(rest, Backoff(rest.Attempts));
        }
        CheckJob(job);
    }

    void Complete(Piece piece)
    {
        piece.Done = true;
        var job = piece.Job;
        // Respaldo: el primero que termina gana.
        if (piece.Hedge is { Done: false } hedge)
        {
            Detach(hedge);
            job.Pieces.Remove(hedge);
            waiting.Remove(hedge);
            piece.Hedge = null;
        }
        if (piece.HedgeOf is { Done: false } original)
        {
            Detach(original);
            waiting.Remove(original);
            original.Data.Truncate(piece.Start - original.Start);
            original.End = piece.Start - 1;
            original.Done = true;
            original.Hedge = null;
            piece.HedgeOf = null;
        }
        CheckJob(job);
    }

    void CheckJob(Job job)
    {
        if (job.Finished || !job.Pieces.All(p => p.Done)) return;
        var data = new MemoryStream();
        var offset = 0;
        foreach (var piece in job.Pieces.OrderBy(p => p.Start).ToList())
        {
            if (piece.Data.IsEmpty) continue;
            if (piece.Start > offset)
            {
                // Hueco (no debería pasar): se pide lo que falta.
                RequestMissing(job, offset, piece.Start - 1);
                return;
            }
            var overlap = offset - piece.Start;
            if (overlap < piece.Data.Count)
            {
                data.Write(piece.Data.Span[overlap..]);
                offset = piece.Start + piece.Data.Count;
            }
        }
        if (job.Total is { } total && offset < total)
        {
            RequestMissing(job, offset, total - 1);
            return;
        }
        if (data.Length == 0)
        {
            Fail(job, new Failure(FailureKind.Http, 0));
            return;
        }
        job.Finished = true;
        job.Pieces.Clear();
        job.Completion(new FetchResult(data.ToArray(), default));
    }

    void RequestMissing(Job job, int lower, int upper)
    {
        var piece = new Piece(job, lower, upper);
        job.Pieces.Add(piece);
        Requeue(piece, 0);
        Dispatch();
    }

    void Fail(Job job, Failure failure)
    {
        if (job.Finished) return;
        job.Finished = true;
        foreach (var piece in job.Pieces.ToList()) Detach(piece);
        waiting.RemoveAll(p => p.Job == job);
        job.Pieces.Clear();
        job.Completion(new FetchResult(null, failure));
    }

    // MARK: - Eventos de red (en la cola)

    /// Devuelve si se sigue leyendo el cuerpo.
    bool OnResponse(Request request, int status, long? contentLength, long? rangeTotal)
    {
        if (!active.TryGetValue(request, out var piece)) return false;
        var job = piece.Job;
        bool allow;

        switch (status)
        {
            case 206:
                if (rangeTotal is { } t)
                {
                    job.Total = (int)t;
                    if (piece.End is not { } e || e > t - 1) piece.End = (int)t - 1;
                }
                allow = true;
                break;

            case 200:
                if (piece.Start > 0 || piece.End != null || job.Pieces.Count > 1)
                {
                    // El servidor ignora `Range` y manda el archivo entero: este
                    // trozo pasa a ser el fragmento completo.
                    RangesUnsupported = true;
                    foreach (var other in job.Pieces.Where(o => o != piece).ToList())
                    {
                        Detach(other);
                        waiting.Remove(other);
                    }
                    var whole = new Piece(job, 0, null)
                    {
                        Request = piece.Request,
                        Lane = piece.Lane,
                        RequestedAt = piece.RequestedAt,
                    };
                    if (piece.Lane != null) piece.Lane.Piece = whole;
                    active[request] = whole;
                    job.Pieces = new List<Piece> { whole };
                    return OnResponse(request, status, contentLength, rangeTotal);
                }
                if (contentLength is > 0)
                {
                    job.Total = (int)contentLength.Value;
                    piece.End = job.Total - 1;
                }
                allow = true;
                break;

            case 416:
                // Trozo más allá del final: el fragmento era más pequeño de lo estimado.
                if (rangeTotal is { } total) job.Total = (int)total;
                Detach(piece);
                piece.End = piece.Start - 1;
                Complete(piece);
                allow = false;
                break;

            case 404 or 410:
                Detach(piece);
                piece.NotFound++;
                if (piece.NotFound >= 2) Fail(job, new Failure(FailureKind.NotFound));
                else Requeue(piece, 0.5);   // un fragmento recién publicado a veces tarda un instante
                allow = false;
                break;

            default:
                Detach(piece);
                piece.Attempts++;
                if (piece.Attempts > 6) Fail(job, new Failure(FailureKind.Http, status));
                else Requeue(piece, Backoff(piece.Attempts));
                allow = false;
                break;
        }
        Dispatch();
        return allow;
    }

    void OnData(Request request, byte[] data)
    {
        if (!active.TryGetValue(request, out var piece)) return;
        var now = DateTime.UtcNow;
        piece.FirstByteAt ??= now;
        piece.LastByteAt = now;
        var length = data.Length;
        if (piece.Remaining is { } remaining && length > remaining) length = remaining;
        piece.Data.Append(data.AsSpan(0, length));
        receivedBytes += length;
        if (lastDataAt is { } last)
        {
            busyTime += (now - last).TotalSeconds;
            measuredBytes += length;
        }
        lastDataAt = now;
        if (piece.Remaining == 0)
        {
            Detach(piece);
            Complete(piece);
            Dispatch();
        }
    }

    void OnComplete(Request request, Exception? error)
    {
        if (!active.TryGetValue(request, out var piece)) return;
        if (error == null && (piece.Remaining ?? 0) == 0)
        {
            Detach(piece);
            if (piece.End == null)
            {
                piece.End = piece.NextOffset - 1;
                if (piece.Start == 0 && piece.Job.Total == null) piece.Job.Total = piece.Data.Count;
            }
            Complete(piece);
        }
        else
        {
            // Cortado a medias (o error de red): lo que falta, por una conexión nueva.
            Abandon(piece, renewConnection: error != null);
        }
        Dispatch();
    }
}
