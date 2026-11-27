using System.Runtime.InteropServices;
using FaderSync.GoXLR;
using ObsInterop;

namespace FaderSync.OBS
{
    public static class Plugin
    {
        private static readonly Logger Log = new(nameof(Plugin));

        [UnmanagedCallersOnly(EntryPoint = "obs_module_set_pointer", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static unsafe void obs_module_set_pointer(obs_module* obsModulePointer)
        {
            // Required by libobs even without module-owned data.
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_ver", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static uint obs_module_ver()
        {
            var major = (uint)Obs.Version.Major;
            var minor = (uint)Obs.Version.Minor;
            var patch = (uint)Obs.Version.Build;

            return (major << 24) | (minor << 16) | patch;
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_load", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static bool obs_module_load()
        {
            try
            {
                Log.Info($"Loading {Module.Name} v{Module.Version}");

                GoXlrChannelSyncFilter.Register();

                UtilitySingleton.Start();

                return true;
            }
            catch (Exception exception)
            {
                Log.Error($"Plugin load failed: {exception.Message}");
                return false;
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_unload", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static void obs_module_unload()
        {
            Log.Info("Plugin unloading...");
            try
            {
                UtilitySingleton.Shutdown();
            }
            catch (Exception exception)
            {
                Log.Error($"Plugin shutdown failed: {exception.Message}");
            }
        }

    }
}
