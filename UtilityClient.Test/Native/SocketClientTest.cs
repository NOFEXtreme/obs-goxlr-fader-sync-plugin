using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using GoXLRUtilityClient.Native;

namespace UtilityClient.Test.Native;

[TestFixture]
[TestOf(typeof(SocketClient))]
public class SocketClientTest
{
    private const string Message = "Hello, GoXLR 🎚";
    private static string PipeName => "goxlr-utility-test-" + Guid.NewGuid();

    [Test]
    public async Task SendsBigEndianLengthAndUtf8Message()
    {
        var name = PipeName;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new SocketClient(name);
        await Task.WhenAll(server.WaitForConnectionAsync(timeout.Token), client.ConnectAsync(timeout.Token));

        var expected = Encoding.UTF8.GetBytes(Message);
        var frame = new byte[4 + expected.Length];
        await Task.WhenAll(client.SendMessageAsync(Message, timeout.Token),
            server.ReadExactlyAsync(frame, timeout.Token).AsTask());
        Assert.That(BinaryPrimitives.ReadUInt32BigEndian(frame), Is.EqualTo(expected.Length));
        Assert.That(frame[4..], Is.EqualTo(expected));
    }

    [Test]
    public async Task ReadsBigEndianLengthAndUtf8Message()
    {
        var name = PipeName;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new SocketClient(name);
        await Task.WhenAll(server.WaitForConnectionAsync(timeout.Token), client.ConnectAsync(timeout.Token));

        var body = Encoding.UTF8.GetBytes(Message);
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)body.Length);
        // Windows pipes can wait for a reader before a write completes.
        var received = client.ReadMessageAsync(timeout.Token);
        await server.WriteAsync(header, timeout.Token);
        await server.WriteAsync(body, timeout.Token);

        Assert.That(await received, Is.EqualTo(Message));
    }
}
