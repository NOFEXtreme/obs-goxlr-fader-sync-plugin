using System.Net.WebSockets;
using System.Text;

namespace GoXLRUtilityClient.Native;

public class WebsocketClient : IDisposable
{
    private readonly ClientWebSocket _client = new();
    private readonly byte[] _receiveBuffer = new byte[4096];

    protected Task OpenAsync(Uri uri, CancellationToken cancellationToken)
    {
        _client.Options.KeepAliveInterval = TimeSpan.FromSeconds(10);
        _client.Options.KeepAliveTimeout = TimeSpan.FromSeconds(5);
        return _client.ConnectAsync(uri, cancellationToken);
    }

    protected Task SendMessageAsync(string message, CancellationToken cancellationToken)
    {
        var bytes = new ArraySegment<byte>(Encoding.UTF8.GetBytes(message));
        return _client.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken);
    }

    protected async Task<string?> ReceiveMessageAsync(CancellationToken cancellationToken)
    {
        var result = await ReceiveAsync(cancellationToken).ConfigureAwait(false);
        if (result.MessageType == WebSocketMessageType.Close) return null;
        if (result.EndOfMessage) return Encoding.UTF8.GetString(_receiveBuffer, 0, result.Count);

        using var message = new MemoryStream();
        while (true)
        {
            if (message.Length + result.Count > SocketClient.MaxMessageLength)
                throw new InvalidDataException("GoXLR Utility websocket message is too large.");

            message.Write(_receiveBuffer, 0, result.Count);
            if (result.EndOfMessage)
                return Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);

            result = await ReceiveAsync(cancellationToken).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) return null;
        }
    }

    private async ValueTask<ValueWebSocketReceiveResult> ReceiveAsync(CancellationToken cancellationToken)
    {
        var result = await _client.ReceiveAsync(_receiveBuffer.AsMemory(), cancellationToken).ConfigureAwait(false);
        if (result.MessageType == WebSocketMessageType.Close)
        {
            await _client.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, cancellationToken).ConfigureAwait(false);
        }
        else if (result.MessageType != WebSocketMessageType.Text)
        {
            throw new InvalidDataException("Expected a text message from GoXLR Utility.");
        }

        return result;
    }

    public void Dispose() => _client.Dispose();
}
