using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using GoXLRUtilityClient.Native;
using Json.Patch;

namespace GoXLRUtilityClient;

public class Utility : WebsocketClient
{
    private const ulong StatusRequestId = 1;
    private static readonly TimeSpan ConnectionTimeout = TimeSpan.FromSeconds(5);
    private JsonObject? _status;

    public JsonObject? Status => Volatile.Read(ref _status);

    public async Task ConnectAsync(CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ConnectionTimeout);

        var pipeName = OperatingSystem.IsWindows() ? "@goxlr.socket" : "/tmp/goxlr.socket";
        string response;
        using (var socketClient = new SocketClient(pipeName))
        {
            await socketClient.ConnectAsync(timeout.Token).ConfigureAwait(false);
            await socketClient.SendMessageAsync("\"GetStatus\"", timeout.Token).ConfigureAwait(false);
            response = await socketClient.ReadMessageAsync(timeout.Token).ConfigureAwait(false);
        }

        var httpSettings = JsonNode.Parse(response)?["Status"]?["config"]?["http_settings"];
        var host = httpSettings?["bind_address"]?.GetValue<string>();
        var port = httpSettings?["port"]?.GetValue<int>();
        if (string.IsNullOrEmpty(host) || port is not (> 0 and <= 65535))
            throw new InvalidDataException("GoXLR Utility did not report a valid websocket address.");

        var address = host switch { "0.0.0.0" => "127.0.0.1", "::" => "::1", _ => host };
        var uri = new UriBuilder("ws", address, port.Value, "/api/websocket").Uri;
        await GetStatusAsync(uri, timeout.Token).ConfigureAwait(false);
    }

    public async Task ConnectAsync(Uri uri, CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ConnectionTimeout);
        await GetStatusAsync(uri, timeout.Token).ConfigureAwait(false);
    }

    private async Task GetStatusAsync(Uri uri, CancellationToken cancellationToken)
    {
        await OpenAsync(uri, cancellationToken).ConfigureAwait(false);
        await SendMessageAsync($$"""{"id":{{StatusRequestId}},"data":"GetStatus"}""", cancellationToken).ConfigureAwait(false);

        while (await ReceiveMessageAsync(cancellationToken).ConfigureAwait(false) is { } message)
        {
            var data = ReadData(message, out var id);
            if (id != StatusRequestId) continue;

            if (data["Status"] is not JsonObject status || status["mixers"] is not JsonObject)
                throw new InvalidDataException("GoXLR Utility returned an invalid status snapshot.");

            Volatile.Write(ref _status, status);
            return;
        }

        throw new EndOfStreamException("GoXLR Utility disconnected before sending its status.");
    }

    public async Task ReceiveUpdatesAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (await ReceiveMessageAsync(cancellationToken).ConfigureAwait(false) is { } message)
            {
                var data = ReadData(message, out _);
                if (!data.TryGetPropertyValue("Patch", out var changes)) continue;
                if (changes is not JsonArray) throw new JsonException("GoXLR Utility returned an invalid patch.");

                var patch = changes.Deserialize(UtilityJsonContext.Default.JsonPatch)!;
                var result = patch.Apply(Status);
                // Patch.Apply creates a copy, so readers can finish using the published snapshot.
                if (!result.IsSuccess || result.Result is not JsonObject status || status["mixers"] is not JsonObject)
                    throw new InvalidDataException("GoXLR Utility patch could not be applied to the current status.");

                Volatile.Write(ref _status, status);
            }
        }
        finally
        {
            Volatile.Write(ref _status, null);
        }
    }

    private static JsonObject ReadData(string message, out ulong id)
    {
        if (JsonNode.Parse(message) is not JsonObject root || root["id"] is not JsonValue idValue ||
            !idValue.TryGetValue(out id) || root["data"] is not JsonObject data)
            throw new JsonException("GoXLR Utility returned an invalid websocket message.");

        return data;
    }
}

[JsonSerializable(typeof(JsonPatch))]
internal partial class UtilityJsonContext : JsonSerializerContext;
