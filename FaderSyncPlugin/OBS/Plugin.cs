using System.Runtime.InteropServices;
using FaderSync.GoXLR;
using ObsInterop;

namespace FaderSync.OBS
{
    public static class Plugin
    {
        private static readonly Logger Log = new Logger(typeof(Plugin), Module.Name);

        [UnmanagedCallersOnly(EntryPoint = "obs_module_set_pointer", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static unsafe void obs_module_set_pointer(obs_module* obsModulePointer)
        {
            // do nothing, needs to exist for OBS to load
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
            Log.Info($"Loading {Module.Name} v{Module.Version}");
            
            Log.Info("Preparing Utility Client...");
            _ = UtilitySingleton.GetInstance();
            
            Log.Info("Loading filters...");
            GoXlrChannelSyncFilter.Register(Module.Name);
            
            Log.Info("Preloading complete.");
            return true;
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_post_load", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static void obs_module_post_load()
        {
            Log.Info("Plugin loaded!");
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_unload", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static void obs_module_unload()
        {
            Log.Info("Plugin unloading...");
            GoXlrChannelSyncFilter.Cleanup();
            UtilitySingleton.GetInstance().Dispose();
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_set_locale", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static unsafe void obs_module_set_locale(char* locale)
        {
            // TODO: add locale support
        }

        [UnmanagedCallersOnly(EntryPoint = "obs_module_free_locale", CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        public static void obs_module_free_locale()
        {
            // do nothing, needs to exist for OBS to load
        }
    }
}