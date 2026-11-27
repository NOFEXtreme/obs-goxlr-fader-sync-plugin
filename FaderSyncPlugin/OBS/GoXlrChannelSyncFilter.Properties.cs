using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using FaderSync.GoXLR;
using ObsInterop;

namespace FaderSync.OBS;

internal static unsafe partial class GoXlrChannelSyncFilter
{
    private static ReadOnlySpan<byte> DeviceKey => "DEVICE_SERIAL"u8;
    private static ReadOnlySpan<byte> ChannelKey => "CHANNEL_NAME"u8;
    private static ReadOnlySpan<byte> SubmixKey => "SUBMIX"u8;
    private static ReadOnlySpan<byte> VolumeOffsetKey => "VOLUME_OFFSET"u8;
    private static ReadOnlySpan<byte> MuteKey => "MUTE_BEHAVIOUR"u8;
    private static ReadOnlySpan<byte> VerboseKey => "VERBOSE_LOGGING"u8;

    private static void SelectDefaultDevice(obs_data* settings)
    {
        if (GetMixers(UtilitySingleton.Status) is not { Count: 1 } mixers) return;
        fixed (byte* key = DeviceKey)
        {
            // A saved serial remains selected when opening OBS without that mixer.
            if (ReadString(settings, key).Length != 0) return;
            foreach (var mixer in mixers)
            {
                fixed (byte* serial = Encoding.UTF8.GetBytes(mixer.Key + '\0'))
                    ObsData.obs_data_set_string(settings, (sbyte*)key, (sbyte*)serial);
            }
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void GetDefaults(obs_data* settings)
    {
        fixed (byte* mix = SubmixKey, a = "A"u8, mute = MuteKey, syncMute = "MUTE_CHANNEL"u8, verbose = VerboseKey)
        {
            ObsData.obs_data_set_default_string(settings, (sbyte*)mix, (sbyte*)a);
            ObsData.obs_data_set_default_string(settings, (sbyte*)mute, (sbyte*)syncMute);
            ObsData.obs_data_set_default_bool(settings, (sbyte*)verbose, 0);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static obs_properties* GetProperties(void* data)
    {
        var properties = ObsProperties.obs_properties_create();
        try
        {
            var settings = data is null ? null : GetContext(data).Settings;
            var mixers = GetMixers(UtilitySingleton.Status);
            var devices = AddList(properties, DeviceKey, "Device"u8, obs_combo_type.OBS_COMBO_TYPE_LIST);
            PopulateDevices(devices, mixers, settings?.DeviceSerial ?? "");

            var channels = AddList(properties, ChannelKey, "Channel"u8, obs_combo_type.OBS_COMBO_TYPE_LIST);
            AddItem(channels, "Microphone"u8, "Mic"u8);
            AddItem(channels, "Chat"u8, "Chat"u8);
            AddItem(channels, "Music"u8, "Music"u8);
            AddItem(channels, "Game"u8, "Game"u8);
            AddItem(channels, "Console"u8, "Console"u8);
            AddItem(channels, "Line In"u8, "LineIn"u8);
            AddItem(channels, "System"u8, "System"u8);
            AddItem(channels, "Samples / VOD"u8, "Sample"u8);
            AddItem(channels, "Headphones"u8, "Headphones"u8);
            AddItem(channels, "Mic Monitor"u8, "MicMonitor"u8);
            AddItem(channels, "Line Out"u8, "LineOut"u8);

            var submix = AddList(properties, SubmixKey, "Submix"u8, obs_combo_type.OBS_COMBO_TYPE_RADIO);
            AddItem(submix, "Submix A / Default Mix"u8, "A"u8);
            AddItem(submix, "Submix B"u8, "B"u8);
            ObsProperties.obs_property_set_enabled(submix, settings is not null &&
                SubmixAvailable(mixers, settings.DeviceSerial, settings.ChannelName) ? (byte)1 : (byte)0);
            ObsProperties.obs_property_set_modified_callback(devices, &UpdateSubmixAvailability);
            ObsProperties.obs_property_set_modified_callback(channels, &UpdateSubmixAvailability);

            fixed (byte* offset = VolumeOffsetKey, title = "Volume Offset (dB)"u8)
                ObsProperties.obs_properties_add_float(properties, (sbyte*)offset, (sbyte*)title, -60, 60, 0.1);

            var mute = AddList(properties, MuteKey, "Mute Behaviour"u8, obs_combo_type.OBS_COMBO_TYPE_RADIO);
            AddItem(mute, "Sync OBS Mute"u8, "MUTE_CHANNEL"u8);
            AddItem(mute, "Manual OBS Mute"u8, "FADER_VOLUME"u8);
            fixed (byte* help = "Sync OBS Mute follows GoXLR on the OBS mute button. Manual OBS Mute sets volume to silence and leaves the OBS mute button under your control."u8)
                ObsProperties.obs_property_set_long_description(mute, (sbyte*)help);

            fixed (byte* verbose = VerboseKey, title = "Verbose logging"u8)
                ObsProperties.obs_properties_add_bool(properties, (sbyte*)verbose, (sbyte*)title);
            return properties;
        }
        catch (Exception exception)
        {
            ObsProperties.obs_properties_destroy(properties);
            Log.Error($"Could not get filter properties: {exception.Message}");
            return null;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static byte UpdateSubmixAvailability(obs_properties* properties, obs_property* property, obs_data* settings)
    {
        try
        {
            fixed (byte* mix = SubmixKey, device = DeviceKey, channel = ChannelKey)
            {
                var submix = ObsProperties.obs_properties_get(properties, (sbyte*)mix);
                var enabled = SubmixAvailable(GetMixers(UtilitySingleton.Status),
                    ReadString(settings, device), ReadString(settings, channel)) ? (byte)1 : (byte)0;
                if (ObsProperties.obs_property_enabled(submix) == enabled) return 0;
                ObsProperties.obs_property_set_enabled(submix, enabled);
                return 1;
            }
        }
        catch (Exception exception)
        {
            Log.Error($"Could not update Submix availability: {exception.Message}");
            return 0;
        }
    }

    private static bool SubmixAvailable(JsonObject? mixers, string serial, string channel) =>
        !HasSharedVolume(channel) &&
        ((mixers?[serial] as JsonObject)?["levels"] as JsonObject)?["submix"] is JsonObject submix &&
        TryReadLevel(((submix["inputs"] as JsonObject)?[channel] as JsonObject)?["volume"], out _);

    private static string? DeviceType(JsonNode? mixer) =>
        ((mixer as JsonObject)?["hardware"] as JsonObject)?["device_type"] is JsonValue value &&
        value.TryGetValue<string>(out var model) ? model : null;

    private static bool PropertiesChanged(JsonObject? previous, JsonObject? current, FilterSettings settings)
    {
        if (previous?.Count != current?.Count) return true;
        if (current is null) return false;

        foreach (var (serial, mixer) in current)
            if (!previous!.TryGetPropertyValue(serial, out var oldMixer) || DeviceType(mixer) != DeviceType(oldMixer))
                return true;

        return SubmixAvailable(previous, settings.DeviceSerial, settings.ChannelName) !=
               SubmixAvailable(current, settings.DeviceSerial, settings.ChannelName);
    }

    private static void PopulateDevices(obs_property* list, JsonObject? mixers, string serial)
    {
        if (serial is "" or "---ERROR---")
        {
            AddItem(list, mixers is null ? "GoXLR Utility disconnected" :
                mixers.Count == 0 ? "No GoXLR devices detected" : "Select a device", serial);
            ObsProperties.obs_property_list_item_disable(list, 0, 1);
        }
        else if (mixers?.ContainsKey(serial) != true)
        {
            AddItem(list, $"{serial} (Disconnected)", serial);
            ObsProperties.obs_property_list_item_disable(list, 0, 1);
        }

        if (mixers is null) return;
        foreach (var mixer in mixers)
        {
            var model = DeviceType(mixer.Value) switch { "Full" => "GoXLR Full", "Mini" => "GoXLR Mini", _ => "GoXLR" };
            AddItem(list, $"{model} ({mixer.Key})", mixer.Key);
        }
    }

    private static obs_property* AddList(obs_properties* properties, ReadOnlySpan<byte> key, ReadOnlySpan<byte> title,
        obs_combo_type type)
    {
        fixed (byte* name = key, description = title)
            return ObsProperties.obs_properties_add_list(properties, (sbyte*)name, (sbyte*)description,
                type, obs_combo_format.OBS_COMBO_FORMAT_STRING);
    }

    private static void AddItem(obs_property* list, ReadOnlySpan<byte> title, ReadOnlySpan<byte> value)
    {
        fixed (byte* name = title, id = value)
            ObsProperties.obs_property_list_add_string(list, (sbyte*)name, (sbyte*)id);
    }

    private static void AddItem(obs_property* list, string title, string value) =>
        AddItem(list, Encoding.UTF8.GetBytes(title + '\0'), Encoding.UTF8.GetBytes(value + '\0'));
}
