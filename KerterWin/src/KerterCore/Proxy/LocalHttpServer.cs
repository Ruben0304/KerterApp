using System.Net;
using System.Net.Sockets;
using System.Text;

namespace KerterCore.Proxy;

/// Servidor HTTP mínimo (solo 127.0.0.1) para que el reproductor lea lo
/// grabado. Cubre HLS con GET/HEAD/OPTIONS, `Range`, CORS y keep-alive.
/// El manejador se ejecuta en la cola del grabador (lo garantiza quien lo da).
internal sealed class LocalHttpServer
{
    public sealed record Response(string ContentType, byte[] Body, int Status = 200);

    readonly Func<string, Task<Response?>> handler;
    readonly CancellationTokenSource cts = new();
    readonly object gate = new();
    readonly HashSet<TcpClient> connections = new();
    TcpListener? listener;
    public int Port { get; private set; }

    public LocalHttpServer(Func<string, Task<Response?>> handler) => this.handler = handler;

    /// Arranca en un puerto libre de loopback.
    public bool Start()
    {
        try
        {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        catch
        {
            return false;
        }
        _ = Task.Run(AcceptLoop);
        return Port != 0;
    }

    public void Stop()
    {
        cts.Cancel();
        try { listener?.Stop(); } catch { }
        lock (gate)
        {
            foreach (var c in connections) { try { c.Close(); } catch { } }
            connections.Clear();
        }
    }

    async Task AcceptLoop()
    {
        while (!cts.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener!.AcceptTcpClientAsync(cts.Token); }
            catch { return; }
            lock (gate) connections.Add(client);
            _ = Task.Run(() => Serve(client));
        }
    }

    static readonly byte[] HeaderEnd = { 13, 10, 13, 10 };

    async Task Serve(TcpClient client)
    {
        try
        {
            client.NoDelay = true;
            var stream = client.GetStream();
            var pending = new List<byte>();
            var buf = new byte[16 * 1024];
            while (!cts.IsCancellationRequested)
            {
                var n = await stream.ReadAsync(buf, cts.Token);
                if (n == 0) break;
                pending.AddRange(buf.AsSpan(0, n).ToArray());
                // Con keep-alive pueden llegar varias peticiones seguidas.
                int end;
                while ((end = IndexOf(pending, HeaderEnd)) >= 0)
                {
                    var head = Encoding.UTF8.GetString(pending.GetRange(0, end).ToArray());
                    pending.RemoveRange(0, end + 4);
                    await Respond(head, stream);
                }
                if (pending.Count > 64 * 1024) break;
            }
        }
        catch { }
        finally
        {
            lock (gate) connections.Remove(client);
            try { client.Close(); } catch { }
        }
    }

    static int IndexOf(List<byte> data, byte[] pattern)
    {
        for (var i = 0; i + pattern.Length <= data.Count; i++)
        {
            var ok = true;
            for (var j = 0; j < pattern.Length && ok; j++) ok = data[i + j] == pattern[j];
            if (ok) return i;
        }
        return -1;
    }

    async Task Respond(string head, NetworkStream stream)
    {
        var lines = head.Split("\r\n");
        var request = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (request.Length < 2) { await Send(stream, 400); return; }
        var method = request[0];
        if (method != "GET" && method != "HEAD" && method != "OPTIONS") { await Send(stream, 405); return; }
        if (method == "OPTIONS") { await Send(stream, 204, includeBody: false); return; }

        var path = request[1].Split('?')[0];
        var response = await handler(path);
        if (response == null) { await Send(stream, 404); return; }

        var status = response.Status;
        var body = response.Body;
        var extra = "";
        if (status == 200 && Header("range", lines) is { } range)
        {
            if (ByteRange(range, body.Length) is not var (lower, upper))
            {
                await Send(stream, 416, extra: $"Content-Range: bytes */{body.Length}\r\n");
                return;
            }
            extra = $"Content-Range: bytes {lower}-{upper}/{body.Length}\r\n";
            body = body[lower..(upper + 1)];
            status = 206;
        }
        await Send(stream, status, response.ContentType, body, extra, includeBody: method == "GET");
    }

    static async Task Send(NetworkStream stream, int status, string contentType = "text/plain",
                           byte[]? body = null, string extra = "", bool includeBody = true)
    {
        body ??= Array.Empty<byte>();
        var reason = status switch
        {
            200 => "OK", 204 => "No Content", 206 => "Partial Content", 400 => "Bad Request",
            404 => "Not Found", 405 => "Method Not Allowed", 416 => "Range Not Satisfiable", _ => "Error",
        };
        var header = $"HTTP/1.1 {status} {reason}\r\n"
            + $"Content-Type: {contentType}\r\n"
            + $"Content-Length: {body.Length}\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Range, Accept, Content-Type\r\n"
            + "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n"
            + "Connection: keep-alive\r\n"
            + extra + "\r\n";
        var head = Encoding.ASCII.GetBytes(header);
        await stream.WriteAsync(head);
        if (includeBody && body.Length > 0) await stream.WriteAsync(body);
        await stream.FlushAsync();
    }

    static string? Header(string name, string[] lines)
    {
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) continue;
            if (line[..colon].Trim().ToLowerInvariant() == name) return line[(colon + 1)..].Trim();
        }
        return null;
    }

    /// `bytes=a-b`, `bytes=a-` o `bytes=-n` → rango inclusivo dentro de `count`.
    internal static (int Lower, int Upper)? ByteRange(string value, int count)
    {
        if (!value.StartsWith("bytes=", StringComparison.Ordinal) || count <= 0) return null;
        var spec = value["bytes=".Length..].Split(',')[0];
        var parts = spec.Split('-');
        if (parts.Length != 2) return null;
        if (parts[0].Length == 0)
        {
            if (!int.TryParse(parts[1], out var suffix) || suffix <= 0) return null;
            return (Math.Max(0, count - suffix), count - 1);
        }
        if (!int.TryParse(parts[0], out var lower) || lower >= count) return null;
        var upper = parts[1].Length == 0 ? count - 1
            : Math.Min(int.TryParse(parts[1], out var u) ? u : count - 1, count - 1);
        return upper >= lower ? (lower, upper) : null;
    }
}
