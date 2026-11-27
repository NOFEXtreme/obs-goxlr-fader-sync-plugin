using System.Text;
using ObsInterop;

namespace FaderSync.OBS;

internal sealed class Logger(string name)
{
    private unsafe void Log(int level, string message)
    {
        fixed (byte* text = Encoding.UTF8.GetBytes($"[{Module.Name}] <{name}> {message.Replace("%", "%%")}\0"))
            ObsBase.blog(level, (sbyte*)text);
    }

    public void Error(string message) => Log(ObsBase.LOG_ERROR, message);
    public void Warning(string message) => Log(ObsBase.LOG_WARNING, message);
    public void Info(string message) => Log(ObsBase.LOG_INFO, message);
}
