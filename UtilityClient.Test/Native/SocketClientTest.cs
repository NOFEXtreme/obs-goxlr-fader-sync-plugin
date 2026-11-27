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
    public async Task ConnectsToPipeServer()
    {
        var name = PipeName;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new SocketClient(name);

        await Task.WhenAll(server.WaitForConnectionAsync(timeout.Token), client.ConnectAsync(timeout.Token));

        Assert.That(server.IsConnected, Is.True);
    }

    [Test]
    public async Task SendsBigEndianLengthAndUtf8Message()
    {
        var name = PipeName;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new SocketClient(name);
        await Task.WhenAll(server.WaitForConnectionAsync(timeout.Token), client.ConnectAsync(timeout.Token));

        await client.SendMessageAsync(Message, timeout.Token);

        var expected = Encoding.UTF8.GetBytes(Message);
        var frame = new byte[4 + expected.Length];
        await server.ReadExactlyAsync(frame, timeout.Token);
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
        await server.WriteAsync(header, timeout.Token);
        await server.WriteAsync(body, timeout.Token);

        Assert.That(await client.ReadMessageAsync(timeout.Token), Is.EqualTo(Message));
    }
}
