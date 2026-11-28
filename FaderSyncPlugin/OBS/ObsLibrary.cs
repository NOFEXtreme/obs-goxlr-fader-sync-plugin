using System.Runtime.InteropServices;
using ObsInterop;

namespace FaderSync.OBS;

internal static partial class ObsLibrary
{
    private const int OpenLoadedLibrary = 6; // RTLD_NOW | RTLD_NOLOAD
    private static nint _handle;

    public static void Bind()
    {
        if (!OperatingSystem.IsLinux() || _handle != 0) return;

        // Debian and the OBS Ubuntu packages use different SONAMEs.
        var handle = Open("libobs.so.0", OpenLoadedLibrary);
        if (handle == 0) handle = Open("libobs.so.30", OpenLoadedLibrary);
        if (handle == 0) handle = Open("libobs.so", OpenLoadedLibrary);
        if (handle == 0) throw new DllNotFoundException("The running OBS process has no supported libobs library loaded.");

        NativeLibrary.SetDllImportResolver(typeof(Obs).Assembly, (name, _, _) => name == "obs" ? handle : 0);
        _handle = handle;
    }

    [LibraryImport("libdl.so.2", EntryPoint = "dlopen", StringMarshalling = StringMarshalling.Utf8)]
    private static partial nint Open(string fileName, int flags);
}
