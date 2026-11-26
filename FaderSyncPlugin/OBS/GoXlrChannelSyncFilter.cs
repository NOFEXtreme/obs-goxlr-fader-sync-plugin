using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using FaderSync.GoXLR;
using ObsInterop;

namespace FaderSync.OBS;

// ReSharper disable once ClassNeverInstantiated.Global
public class GoXlrChannelSyncFilter
{
    private static readonly Logger Log = new(typeof(Plugin));
    private static IntPtr _filterIdPtr = IntPtr.Zero;

    /**
     * Registers the Filter in OBS.
     */
    public static unsafe void Register(string moduleBaseName)
    {
        if (_filterIdPtr != IntPtr.Zero) return;

        var sourceInfo = new obs_source_info();
        var filterId = $"{moduleBaseName}/{nameof(GoXlrChannelSyncFilter)}";

        _filterIdPtr = Marshal.StringToCoTaskMemUTF8(filterId);

        sourceInfo.id = (sbyte*)_filterIdPtr;
        sourceInfo.type = obs_source_type.OBS_SOURCE_TYPE_FILTER;
        sourceInfo.output_flags = ObsSource.OBS_SOURCE_AUDIO;
        sourceInfo.get_name = &GetName;
        sourceInfo.create = &Create;
        sourceInfo.destroy = &Destroy;
        sourceInfo.video_tick = &Tick;
        sourceInfo.filter_add = &FilterAdd;
        sourceInfo.filter_remove = &FilterRemove;
        sourceInfo.update = &Update;
        sourceInfo.get_defaults = &GetDefaults;
        sourceInfo.get_properties = &GetProperties;

        ObsSource.obs_register_source_s(&sourceInfo, (nuint)Marshal.SizeOf(sourceInfo));
    }

    public static void Cleanup()
    {
        if (_filterIdPtr == IntPtr.Zero) return;
        Marshal.FreeCoTaskMem(_filterIdPtr);
        _filterIdPtr = IntPtr.Zero;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe sbyte* GetName(void* data)
    {
        fixed (byte* namePtr = "Sync volume with GoXLR Channel"u8)
        {
            return (sbyte*)namePtr;
        }
    }

    /**
     * Initialized the Filter for OBS and also creates a context since this is not a class.
     * This function can be seen as some sort of constructor.
     */
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void* Create(obs_data* settings, obs_source* source)
    {
        try
        {
            var context = new FilterContext(source, ReadSettings(settings));
            Log.Debug("Filter created!");
            return (void*)GCHandle.ToIntPtr(GCHandle.Alloc(context));
        }
        catch (Exception exception)
        {
            Log.Error($"Could not create filter: {exception.Message}");
            return null;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void Destroy(void* data)
    {
        if (data is null) return;
        var handle = GCHandle.FromIntPtr((IntPtr)data);
        try
        {
            ((FilterContext)handle.Target!).SetParent(null);
            Log.Debug("Filter destroyed!");
        }
        catch (Exception exception)
        {
            Log.Error($"Could not destroy filter: {exception.Message}");
        }
        finally
        {
            handle.Free();
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void FilterAdd(void* data, obs_source* parent) => SetParent(data, parent);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void FilterRemove(void* data, obs_source* parent) => SetParent(data, null);

    private static unsafe void SetParent(void* data, obs_source* parent)
    {
        if (data is null) return;
        try
        {
            GetContext(data).SetParent(parent);
        }
        catch (Exception exception)
        {
            Log.Error($"Could not update filter parent: {exception.Message}");
        }
    }

    private static unsafe FilterContext GetContext(void* data) =>
        (FilterContext)GCHandle.FromIntPtr((IntPtr)data).Target!;

    /**
     * Gets called every frame.
     * Requests current volume from the GoXLR Utility and translates the volume to the OBS volume scale.
     */
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void Tick(void* data, float seconds)
    {
        if (data is null) return;
        obs_source* target = null;
        try
        {
            var context = GetContext(data);
            if (Obs.obs_source_enabled(context.Source) == 0) return;

            var settings = context.Settings;
            if (!TryGetChannelState(UtilitySingleton.Status, settings, out var level, out var muted)) return;

            target = context.GetParent();
            if (target is null) return;

            var volume = ChannelVolume.ToObsVolume(level, settings.OffsetMultiplier);
            ApplyVolumeAndMute(target, settings, volume, muted);
        }
        catch (Exception e)
        {
            Log.Error($"Tick exception: {e}");
        }
        finally
        {
            if (target is not null) Obs.obs_source_release(target);
        }
    }

    private static bool TryGetChannelState(JsonObject? status, FilterSettings settings, out int level, out bool muted)
    {
        level = 0;
        muted = false;
        if (status?["mixers"] is not JsonObject mixers ||
            mixers[settings.DeviceSerial] is not JsonObject mixer ||
            mixer["levels"] is not JsonObject levels ||
            mixer["fader_status"] is not JsonObject { Count: > 0 } faders)
            return false;

        JsonNode? volume;
        var submix = levels["submix"];
        // Utility gives output channels one shared level and supplies B values for inputs only.
        var hasSubmixVolume = settings.ChannelName is not ("Headphones" or "MicMonitor" or "LineOut");
        if (settings.SubmixB && hasSubmixVolume && submix is not null)
        {
            var inputs = (submix as JsonObject)?["inputs"] as JsonObject;
            volume = (inputs?[settings.ChannelName] as JsonObject)?["volume"];
        }
        else
        {
            volume = (levels["volumes"] as JsonObject)?[settings.ChannelName];
        }

        if (volume is not JsonValue value || !value.TryGetValue(out level) || level is < 0 or > 255)
            return false;

        foreach (var entry in faders)
        {
            if (entry.Value is not JsonObject fader || fader["channel"] is not JsonValue channel ||
                !channel.TryGetValue<string>(out var channelName))
                return false;
            if (channelName != settings.ChannelName) continue;

            if (fader["mute_state"] is not JsonValue muteState || !muteState.TryGetValue<string>(out var state))
                return false;
            switch (state)
            {
                case "MutedToAll":
                    muted = true;
                    return true;
                case "Unmuted":
                    return true;
                case "MutedToX":
                    if (fader["mute_type"] is not JsonValue muteType || !muteType.TryGetValue<string>(out var type))
                        return false;
                    muted = type is "ToStream" or "All";
                    return muted || type is "ToVoiceChat" or "ToPhones" or "ToLineOut" or "ToStream2" or "ToStreams";
                default:
                    return false;
            }
        }

        // An incomplete list cannot tell us whether this channel is unassigned.
        return faders.ContainsKey("A") && faders.ContainsKey("B") && faders.ContainsKey("C") && faders.ContainsKey("D");
    }

    private static unsafe void ApplyVolumeAndMute(obs_source* target, FilterSettings settings, float volume, bool muted)
    {
        if (settings.MuteViaVolume && muted) volume = 0;
        if (!float.IsFinite(volume)) return;

        var volumeChanged = Obs.obs_source_get_volume(target) != volume;
        var muteChanged = !settings.MuteViaVolume && (Obs.obs_source_muted(target) != 0) != muted;
        if (muteChanged && muted) Obs.obs_source_set_muted(target, 1);
        if (volumeChanged) Obs.obs_source_set_volume(target, volume);
        if (muteChanged && !muted) Obs.obs_source_set_muted(target, 0);

        if (settings.VerboseLogging && (volumeChanged || muteChanged))
            Log.Info($"Updated volume for channel '{settings.ChannelName}' to {volume} (GoXLR muted: {muted})");
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void GetDefaults(obs_data* settings)
    {
        try
        {
            fixed (byte* sSubmixId = "SUBMIX"u8, sSubmixDefault = "A"u8,
                   sMuteBehaviourId = "MUTE_BEHAVIOUR"u8, sMuteBehaviourDefault = "MUTE_CHANNEL"u8,
                   sVerboseLoggingId = "VERBOSE_LOGGING"u8)
            {
                ObsData.obs_data_set_default_string(settings, (sbyte*)sSubmixId, (sbyte*)sSubmixDefault);
                ObsData.obs_data_set_default_string(settings, (sbyte*)sMuteBehaviourId, (sbyte*)sMuteBehaviourDefault);
                ObsData.obs_data_set_default_bool(settings, (sbyte*)sVerboseLoggingId, 0);
            }
        }
        catch (Exception exception)
        {
            Log.Error($"Could not set filter defaults: {exception.Message}");
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe obs_properties* GetProperties(void* data)
    {
        obs_properties* properties = null;
        try
        {
            properties = ObsProperties.obs_properties_create();
            var serial = data is null ? null : GetContext(data).Settings.DeviceSerial;
            PopulateProperties(properties, serial);
            return properties;
        }
        catch (Exception exception)
        {
            if (properties is not null) ObsProperties.obs_properties_destroy(properties);
            Log.Error($"Could not get filter properties: {exception.Message}");
            return null;
        }
    }

    private static unsafe void PopulateProperties(obs_properties* properties, string? serial)
    {
        fixed (byte*
            // device serial input
            sDeviceSerialId = "DEVICE_SERIAL"u8,
            sDeviceSerialDescription = "Device Serial"u8,

            // We need a 'Default' serial in case something is wrong when loading
            sDeviceSerialError = "---ERROR---"u8,
            sDeviceSerialDisconnected = "Error Connecting to the GoXLR Utility"u8,
            sDeviceSerialNoDevices = "No GoXLR Devices Detected"u8,
            
            // add channels
            sChannelNameId = "CHANNEL_NAME"u8,
            sChannelNameDescription = "Channel Name"u8,

            // channel names
            sChannelMic = "Microphone"u8,
            sChannelMicId = "Mic"u8,
            sChannelChat = "Chat"u8,
            sChannelChatId = "Chat"u8,
            sChannelMusic = "Music"u8,
            sChannelMusicId = "Music"u8,
            sChannelGame = "Game"u8,
            sChannelGameId = "Game"u8,
            sChannelConsole = "Console"u8,
            sChannelConsoleId = "Console"u8,
            sChannelLineIn = "Line In"u8,
            sChannelLineInId = "LineIn"u8,
            sChannelSystem = "System"u8,
            sChannelSystemId = "System"u8,
            sChannelSample = "Samples / VOD"u8,
            sChannelSampleId = "Sample"u8,
            sChannelHeadphones = "Headphones"u8,
            sChannelHeadphonesId = "Headphones"u8,
            sChannelMicMonitor = "Mic Monitor"u8,
            sChannelMicMonitorId = "MicMonitor"u8,
            sChannelLineOut = "Line Out"u8,
            sChannelLineOutId = "LineOut"u8,

            // Submixes
            sSubmixId = "SUBMIX"u8,
            sSubmixDescription = "Submix (if enabled on GoXLR)"u8,

            sSubmixA = "Submix A / Default Mix"u8,
            sSubmixAId = "A"u8,
            sSubmixB = "Submix B"u8,
            sSubmixBId = "B"u8,
            
            // volume offset
            sVolumeOffsetId = "VOLUME_OFFSET"u8,
            sVolumeOffsetDescription = "Volume Offset (dB)"u8,
            
            // mute behaviour
            sMuteBehaviourId = "MUTE_BEHAVIOUR"u8,
            sMuteBehaviourDescription = "Mute Behaviour"u8,
            sMuteBehaviourObsMute = "Mute Channel"u8,
            sMuteBehaviourObsMuteId = "MUTE_CHANNEL"u8,
            sMuteBehaviourFaderVolume = "Mute via Volume"u8,
            sMuteBehaviourFaderVolumeId = "FADER_VOLUME"u8,

            sVerboseLoggingId = "VERBOSE_LOGGING"u8,
            sVerboseLoggingDescription = "Verbose logging"u8
            )
        {
            // Create the Serial Dropdown...
            var deviceList = ObsProperties.obs_properties_add_list(properties, (sbyte*)sDeviceSerialId, (sbyte*)sDeviceSerialDescription,
                obs_combo_type.OBS_COMBO_TYPE_LIST, obs_combo_format.OBS_COMBO_FORMAT_STRING);
            
            // channel selection list
            var channelList = ObsProperties.obs_properties_add_list(properties, (sbyte*)sChannelNameId,
                (sbyte*)sChannelNameDescription, obs_combo_type.OBS_COMBO_TYPE_LIST,
                obs_combo_format.OBS_COMBO_FORMAT_STRING);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelMic, (sbyte*)sChannelMicId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelChat, (sbyte*)sChannelChatId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelMusic, (sbyte*)sChannelMusicId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelGame, (sbyte*)sChannelGameId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelConsole, (sbyte*)sChannelConsoleId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelLineIn, (sbyte*)sChannelLineInId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelSystem, (sbyte*)sChannelSystemId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelSample, (sbyte*)sChannelSampleId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelHeadphones, (sbyte*)sChannelHeadphonesId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelMicMonitor, (sbyte*)sChannelMicMonitorId);
            ObsProperties.obs_property_list_add_string(channelList, (sbyte*)sChannelLineOut, (sbyte*)sChannelLineOutId);

            // Create the Submix dropdown
            // channel selection list
            var submix = ObsProperties.obs_properties_add_list(properties, (sbyte*)sSubmixId,
                (sbyte*)sSubmixDescription, obs_combo_type.OBS_COMBO_TYPE_RADIO,
                obs_combo_format.OBS_COMBO_FORMAT_STRING);
            ObsProperties.obs_property_list_add_string(submix, (sbyte*)sSubmixA, (sbyte*)sSubmixAId);
            ObsProperties.obs_property_list_add_string(submix, (sbyte*)sSubmixB, (sbyte*)sSubmixBId);
            
            var mixers = UtilitySingleton.Status?["mixers"] as JsonObject;
            if (mixers != null)
            {
                foreach (var mixer in mixers)
                    AddDevice(deviceList, mixer.Key, mixer.Key);
            }

            if (!string.IsNullOrEmpty(serial) && serial != "---ERROR---")
            {
                if (mixers?.ContainsKey(serial) != true)
                    AddDevice(deviceList, $"{serial} - Disconnected", serial);
            }
            else if (mixers == null || mixers.Count == 0)
            {
                var title = mixers == null ? sDeviceSerialDisconnected : sDeviceSerialNoDevices;
                ObsProperties.obs_property_list_add_string(deviceList, (sbyte*)title, (sbyte*)sDeviceSerialError);
            }

            // Add the Volume Offset Property
            ObsProperties.obs_properties_add_float(properties, (sbyte*)sVolumeOffsetId, (sbyte*)sVolumeOffsetDescription, -60, 60, 0.1);

            var muteBehaviourList = ObsProperties.obs_properties_add_list(properties, (sbyte*)sMuteBehaviourId,
                (sbyte*)sMuteBehaviourDescription, obs_combo_type.OBS_COMBO_TYPE_LIST,
                obs_combo_format.OBS_COMBO_FORMAT_STRING);
            ObsProperties.obs_property_list_add_string(muteBehaviourList, (sbyte*)sMuteBehaviourObsMute, (sbyte*)sMuteBehaviourObsMuteId);
            ObsProperties.obs_property_list_add_string(muteBehaviourList, (sbyte*)sMuteBehaviourFaderVolume, (sbyte*)sMuteBehaviourFaderVolumeId);

            ObsProperties.obs_properties_add_bool(properties, (sbyte*)sVerboseLoggingId, (sbyte*)sVerboseLoggingDescription);
        }
    }

    private static unsafe void AddDevice(obs_property* deviceList, string title, string serial)
    {
        fixed (byte* sTitle = Encoding.UTF8.GetBytes(title + '\0'), sSerial = Encoding.UTF8.GetBytes(serial + '\0'))
        {
            ObsProperties.obs_property_list_add_string(deviceList, (sbyte*)sTitle, (sbyte*)sSerial);
        }
    }

    /**
     * Called when the user changes the settings for the filter
     */
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static unsafe void Update(void* data, obs_data* settings)
    {
        if (data is null) return;
        try
        {
            GetContext(data).Settings = ReadSettings(settings);
        }
        catch (Exception exception)
        {
            Log.Error($"Could not update filter settings: {exception.Message}");
        }
    }

    private static unsafe FilterSettings ReadSettings(obs_data* settings)
    {
        fixed (byte* sChannelName = "CHANNEL_NAME"u8, sDeviceSerial = "DEVICE_SERIAL"u8,
               sSubmix = "SUBMIX"u8, sVolumeOffset = "VOLUME_OFFSET"u8,
               sMuteBehaviour = "MUTE_BEHAVIOUR"u8, sVerboseLogging = "VERBOSE_LOGGING"u8)
        {
            return new FilterSettings(
                Marshal.PtrToStringUTF8((IntPtr)ObsData.obs_data_get_string(settings, (sbyte*)sDeviceSerial)) ?? "",
                Marshal.PtrToStringUTF8((IntPtr)ObsData.obs_data_get_string(settings, (sbyte*)sChannelName)) ?? "",
                Marshal.PtrToStringUTF8((IntPtr)ObsData.obs_data_get_string(settings, (sbyte*)sSubmix)) == "B",
                (float)Math.Pow(10, ObsData.obs_data_get_double(settings, (sbyte*)sVolumeOffset) / 20),
                Marshal.PtrToStringUTF8((IntPtr)ObsData.obs_data_get_string(settings, (sbyte*)sMuteBehaviour)) == "FADER_VOLUME",
                ObsData.obs_data_get_bool(settings, (sbyte*)sVerboseLogging) != 0);
        }
    }

    private sealed record FilterSettings(string DeviceSerial, string ChannelName, bool SubmixB,
        float OffsetMultiplier, bool MuteViaVolume, bool VerboseLogging);

    private sealed unsafe class FilterContext(obs_source* source, FilterSettings settings)
    {
        private readonly object _parentLock = new();
        private obs_weak_source* _parent;
        private FilterSettings _settings = settings;

        public readonly obs_source* Source = source;

        public FilterSettings Settings
        {
            get => Volatile.Read(ref _settings);
            set => Volatile.Write(ref _settings, value);
        }

        public void SetParent(obs_source* parent)
        {
            lock (_parentLock)
            {
                var previous = _parent;
                _parent = parent is null ? null : Obs.obs_source_get_weak_source(parent);
                if (previous is not null) Obs.obs_weak_source_release(previous);
            }
        }

        public obs_source* GetParent()
        {
            lock (_parentLock)
            {
                return _parent is null ? null : Obs.obs_weak_source_get_source(_parent);
            }
        }
    }
}
