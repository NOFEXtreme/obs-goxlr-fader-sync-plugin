using System.Text.Json.Nodes;
using FaderSync.OBS;
using GoXLRUtilityClient;

namespace FaderSync.GoXLR;

public static class UtilitySingleton
{
    private static readonly Logger Log = new(nameof(UtilitySingleton));
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(2);
    private static readonly object Lock = new();

    private static Utility? _utility;
    private static CancellationTokenSource? _cancellation;
    private static Task? _connectionTask;

    public static JsonObject? Status => Volatile.Read(ref _utility)?.Status;

    public static void Start()
    {
        lock (Lock)
        {
            if (_cancellation != null) return;
            _cancellation = new CancellationTokenSource();
            var cancellationToken = _cancellation.Token;
            _connectionTask = Task.Run(() => Connect(cancellationToken));
        }
    }

    public static void Shutdown()
    {
        lock (Lock)
        {
            if (_cancellation == null) return;
            try
            {
                _cancellation.Cancel();
                _connectionTask?.GetAwaiter().GetResult();
            }
            finally
            {
                _cancellation.Dispose();
                _cancellation = null;
                _connectionTask = null;
            }
        }
    }

    private static async Task Connect(CancellationToken cancellationToken)
    {
        var reportedFailure = false;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                using (var utility = new Utility())
                {
                    try
                    {
                        await utility.ConnectAsync(cancellationToken).ConfigureAwait(false);
                        Volatile.Write(ref _utility, utility);
                        reportedFailure = false;
                        var version = (utility.Status?["config"] as JsonObject)?["daemon_version"];
                        Log.Info($"Connected to GoXLR Utility v{version}");

                        await utility.ReceiveUpdatesAsync(cancellationToken).ConfigureAwait(false);
                        Log.Warning("GoXLR Utility disconnected. Retrying...");
                        reportedFailure = true;
                    }
                    catch (Exception exception)
                    {
                        if (cancellationToken.IsCancellationRequested) break;
                        if (!reportedFailure)
                            Log.Warning($"GoXLR Utility connection failed: {exception.Message}. Retrying...");
                        reportedFailure = true;
                    }
                    finally
                    {
                        Volatile.Write(ref _utility, null);
                    }
                }

                await Task.Delay(RetryInterval, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }
}
