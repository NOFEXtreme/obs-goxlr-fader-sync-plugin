using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using FaderSync.GoXLR;
using ObsInterop;

namespace FaderSync.OBS;

public static class Plugin
{
    private static readonly Logger Log = new(nameof(Plugin));

    [UnmanagedCallersOnly(EntryPoint = "obs_module_set_pointer", CallConvs = [typeof(CallConvCdecl)])]
    public static unsafe void obs_module_set_pointer(obs_module* obsModulePointer)
    {
        // Required by libobs even without module-owned data.
    }

    [UnmanagedCallersOnly(EntryPoint = "obs_module_ver", CallConvs = [typeof(CallConvCdecl)])]
    public static uint obs_module_ver()
    {
        var major = (uint)Obs.Version.Major;
        var minor = (uint)Obs.Version.Minor;
        var patch = (uint)Obs.Version.Build;

        return (major << 24) | (minor << 16) | patch;
    }

    [UnmanagedCallersOnly(EntryPoint = "obs_module_load", CallConvs = [typeof(CallConvCdecl)])]
    public static bool obs_module_load()
    {
        try
        {
            ObsLibrary.Bind();
            Log.Info($"Loading {Module.Name} v{Module.Version}");

            GoXlrChannelSyncFilter.Register();

            UtilitySingleton.Start();

            return true;
        }
        catch (Exception exception)
        {
            ReportFailure($"Plugin load failed: {exception.Message}");
            return false;
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "obs_module_unload", CallConvs = [typeof(CallConvCdecl)])]
    public static void obs_module_unload()
    {
        try
        {
            UtilitySingleton.Shutdown();
            Log.Info("Plugin unloaded.");
        }
        catch (Exception exception)
        {
            ReportFailure($"Plugin shutdown failed: {exception.Message}");
        }
    }

    private static void ReportFailure(string message)
    {
        try
        {
            Console.Error.WriteLine($"[FaderSyncPlugin] {message}");
        }
        catch (IOException)
        {
        }
    }
}
