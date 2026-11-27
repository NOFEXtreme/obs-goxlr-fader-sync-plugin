using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using FaderSync.GoXLR;
using ObsInterop;

namespace FaderSync.OBS;

internal static unsafe partial class GoXlrChannelSyncFilter
{
    private static readonly Logger Log = new(nameof(GoXlrChannelSyncFilter));

    public static void Register()
    {
        fixed (byte* id = "FaderSyncPlugin/GoXlrChannelSyncFilter"u8)
        {
            var info = new obs_source_info
            {
                id = (sbyte*)id,
                type = obs_source_type.OBS_SOURCE_TYPE_FILTER,
                output_flags = ObsSource.OBS_SOURCE_AUDIO,
                get_name = &GetName,
                create = &Create,
                destroy = &Destroy,
                video_tick = &Tick,
                filter_add = &FilterAdd,
                filter_remove = &FilterRemove,
                update = &Update,
                get_defaults = &GetDefaults,
                get_properties = &GetProperties,
            };
            // libobs retains the original ID as well as its own copy.
            ObsSource.obs_register_source_s(&info, (nuint)sizeof(obs_source_info));
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static sbyte* GetName(void* data)
    {
        fixed (byte* namePtr = "Sync volume with GoXLR Channel"u8)
        {
            return (sbyte*)namePtr;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void* Create(obs_data* settings, obs_source* source)
    {
        try
        {
            SelectDefaultDevice(settings);
            var context = new FilterContext(source, ReadSettings(settings));
            return (void*)GCHandle.ToIntPtr(GCHandle.Alloc(context));
        }
        catch (Exception exception)
        {
            Log.Error($"Could not create filter: {exception.Message}");
            return null;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void Destroy(void* data)
    {
        if (data is null) return;
        var handle = GCHandle.FromIntPtr((IntPtr)data);
        try
        {
            ((FilterContext)handle.Target!).SetParent(null);
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
    private static void FilterAdd(void* data, obs_source* parent) => SetParent(data, parent);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void FilterRemove(void* data, obs_source* parent) => SetParent(data, null);

    private static void SetParent(void* data, obs_source* parent)
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

    private static FilterContext GetContext(void* data) =>
        (FilterContext)GCHandle.FromIntPtr((IntPtr)data).Target!;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void Tick(void* data, float seconds)
    {
        if (data is null) return;
        var context = GetContext(data);
        try
        {
            context.Sync();
            context.ReportedUpdateError = false;
        }
        catch (Exception exception)
        {
            if (!context.ReportedUpdateError) Log.Error($"Could not sync filter: {exception.Message}");
            context.ReportedUpdateError = true;
        }
    }

    private static JsonObject? GetMixers(JsonObject? status) => status?["mixers"] as JsonObject;
    private static bool HasSharedVolume(string channel) => channel is "Headphones" or "MicMonitor" or "LineOut";

    private static bool TryGetChannelState(JsonObject? status, FilterSettings settings, out int level, out bool muted)
    {
        level = 0;
        muted = false;
        if (GetMixers(status) is not { } mixers ||
            mixers[settings.DeviceSerial] is not JsonObject mixer ||
            mixer["levels"] is not JsonObject levels ||
            mixer["fader_status"] is not JsonObject { Count: > 0 } faders)
            return false;

        JsonNode? volume;
        var submix = levels["submix"];
        // Utility gives output channels one shared level and supplies B values for inputs only.
        if (settings.SubmixB && !HasSharedVolume(settings.ChannelName) && submix is not null)
        {
            var inputs = (submix as JsonObject)?["inputs"] as JsonObject;
            volume = (inputs?[settings.ChannelName] as JsonObject)?["volume"];
        }
        else
        {
            volume = (levels["volumes"] as JsonObject)?[settings.ChannelName];
        }

        if (!TryReadLevel(volume, out level))
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
                    muted = type is "ToStream" or "ToStreams" or "All";
                    return muted || type is "ToVoiceChat" or "ToPhones" or "ToLineOut" or "ToStream2";
                default:
                    return false;
            }
        }

        // An incomplete list cannot tell us whether this channel is unassigned.
        return faders.ContainsKey("A") && faders.ContainsKey("B") && faders.ContainsKey("C") && faders.ContainsKey("D");
    }

    private static void ApplyVolumeAndMute(obs_source* target, FilterSettings settings, float volume, bool muted)
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

    private static bool TryReadLevel(JsonNode? node, out int level)
    {
        level = 0;
        return node is JsonValue value && value.TryGetValue(out level) && level is >= 0 and <= 255;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void Update(void* data, obs_data* settings)
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

    private static FilterSettings ReadSettings(obs_data* settings)
    {
        fixed (byte* sChannelName = ChannelKey, sDeviceSerial = DeviceKey, sSubmix = SubmixKey,
               sVolumeOffset = VolumeOffsetKey, sMuteBehaviour = MuteKey, sVerboseLogging = VerboseKey)
        {
            return new FilterSettings(
                ReadString(settings, sDeviceSerial),
                ReadString(settings, sChannelName),
                ReadString(settings, sSubmix) == "B",
                (float)Math.Pow(10, ObsData.obs_data_get_double(settings, (sbyte*)sVolumeOffset) / 20),
                ReadString(settings, sMuteBehaviour) == "FADER_VOLUME",
                ObsData.obs_data_get_bool(settings, (sbyte*)sVerboseLogging) != 0);
        }
    }

    private static string ReadString(obs_data* settings, byte* key) =>
        Marshal.PtrToStringUTF8((IntPtr)ObsData.obs_data_get_string(settings, (sbyte*)key)) ?? "";

    private sealed record FilterSettings(string DeviceSerial, string ChannelName, bool SubmixB,
        float OffsetMultiplier, bool MuteViaVolume, bool VerboseLogging);

    private sealed class FilterContext(obs_source* source, FilterSettings settings)
    {
        private readonly object _parentLock = new();
        private obs_weak_source* _parent;
        private FilterSettings _settings = settings;
        // The video thread owns the last input pair and its calculated state.
        private JsonObject? _lastStatus;
        private FilterSettings? _lastSettings;
        private float _volume;
        private bool _muted, _hasState;

        public bool ReportedUpdateError;

        public FilterSettings Settings
        {
            get => Volatile.Read(ref _settings);
            set => Volatile.Write(ref _settings, value);
        }

        public void Sync()
        {
            var status = UtilitySingleton.Status;
            var current = Settings;
            if (!ReferenceEquals(_lastStatus, status) || !ReferenceEquals(_lastSettings, current))
            {
                var refreshProperties = !ReferenceEquals(_lastStatus, status) &&
                    PropertiesChanged(GetMixers(_lastStatus), GetMixers(status), current);
                _hasState = TryGetChannelState(status, current, out var level, out _muted);
                _volume = _hasState ? ChannelVolume.ToObsVolume(level, current.OffsetMultiplier) : 0;
                _lastStatus = status;
                _lastSettings = current;
                if (refreshProperties) Obs.obs_source_update_properties(source);
            }

            if (!_hasState || Obs.obs_source_enabled(source) == 0) return;
            var parent = GetParent();
            if (parent is null) return;
            try
            {
                ApplyVolumeAndMute(parent, current, _volume, _muted);
            }
            finally
            {
                Obs.obs_source_release(parent);
            }
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

        private obs_source* GetParent()
        {
            lock (_parentLock)
            {
                return _parent is null ? null : Obs.obs_weak_source_get_source(_parent);
            }
        }
    }
}
