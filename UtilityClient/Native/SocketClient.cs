using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;

namespace GoXLRUtilityClient.Native;

public class SocketClient : IDisposable
{
    // GoXLR Utility uses the default limit of the length-delimited codec.
    internal const int MaxMessageLength = 8 * 1024 * 1024;
    private readonly NamedPipeClientStream _client;

    public SocketClient(string socketName)
    {
        _client = new NamedPipeClientStream(".", socketName, PipeDirection.InOut, PipeOptions.Asynchronous);
    }

    public Task ConnectAsync(CancellationToken cancellationToken) => _client.ConnectAsync(cancellationToken);

    public async Task SendMessageAsync(string message, CancellationToken cancellationToken)
    {
        var messageBytes = Encoding.UTF8.GetBytes(message);
        var length = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32BigEndian(length, (uint)messageBytes.Length);

        await _client.WriteAsync(length, cancellationToken).ConfigureAwait(false);
        await _client.WriteAsync(messageBytes, cancellationToken).ConfigureAwait(false);
        await _client.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public Task<string> ReadMessageAsync(CancellationToken cancellationToken) => ReadMessageAsync(_client, cancellationToken);

    internal static async Task<string> ReadMessageAsync(Stream stream, CancellationToken cancellationToken)
    {
        var lengthBytes = new byte[sizeof(uint)];
        await stream.ReadExactlyAsync(lengthBytes, cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadUInt32BigEndian(lengthBytes);
        if (length > MaxMessageLength) throw new InvalidDataException("GoXLR Utility IPC message is too large.");

        var messageBytes = new byte[(int)length];
        await stream.ReadExactlyAsync(messageBytes, cancellationToken).ConfigureAwait(false);
        return Encoding.UTF8.GetString(messageBytes);
    }

    public void Dispose() => _client.Dispose();
}
