using System.Threading.Channels;

namespace KerterCore.Proxy;

/// Cola serial (equivale a la DispatchQueue del original): todo el estado del
/// grabador se toca solo desde aquí, así que no hacen falta candados.
internal sealed class SerialQueue
{
    readonly Channel<Action> channel = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    readonly CancellationTokenSource cts = new();
    public Task Completion { get; }

    public SerialQueue()
    {
        Completion = Task.Run(async () =>
        {
            await foreach (var action in channel.Reader.ReadAllAsync())
            {
                try { action(); }
                catch (Exception e) { ProxyLog.Log(() => $"error en la cola: {e}"); }
            }
        });
    }

    /// false si la cola ya se cerró.
    public bool Post(Action action) => channel.Writer.TryWrite(action);

    public void PostAfter(double seconds, Action action)
    {
        var token = cts.Token;
        Task.Delay(TimeSpan.FromSeconds(seconds), token).ContinueWith(
            _ => Post(action), CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.Default);
    }

    /// Ejecuta en la cola y devuelve el resultado (default si la cola está cerrada).
    public Task<T?> Invoke<T>(Func<T> func)
    {
        var tcs = new TaskCompletionSource<T?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!Post(() => { try { tcs.TrySetResult(func()); } catch (Exception e) { tcs.TrySetException(e); } }))
            tcs.TrySetResult(default);
        return tcs.Task;
    }

    /// Cierra la cola (lo ya encolado se ejecuta) y cancela los retardos pendientes.
    public void Complete()
    {
        cts.Cancel();
        channel.Writer.TryComplete();
    }
}

/// Registro del grabador: se enchufa con `ProxyLog.Sink`.
public static class ProxyLog
{
    public static Action<string>? Sink { get; set; }

    internal static void Log(Func<string> message)
    {
        var sink = Sink;
        if (sink != null) sink(message());
    }
}
