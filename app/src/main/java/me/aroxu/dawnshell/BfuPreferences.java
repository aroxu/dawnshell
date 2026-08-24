package me.aroxu.dawnshell;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;

final class BfuPreferences {

    private static final String PREFS_NAME = "dawnshell";
    private static final String KEY_ENABLED = "enabled";
    private static final String KEY_ALLOW_CE_READABLE_BFU =
            "allow_ce_readable_bfu";
    private static final String KEY_CGROUP_POLICY = "cgroup_policy";
    private static final String KEY_DOCKER_NETWORK_POLICY = "docker_network_policy";
    private static final String KEY_DOCKER_HOST_IPC_COMPATIBILITY =
            "docker_host_ipc_compatibility";
    private static final String KEY_SHARE_HOST_USB_LEGACY = "share_host_usb";
    private static final String KEY_USB_PASSTHROUGH_MODE = "usb_passthrough_mode";
    private static final String KEY_USB_EXCLUSIVE_DEVICE_IDS =
            "usb_exclusive_device_ids";
    private static final String KEY_HARDWARE_CODEC_BRIDGE =
            "hardware_codec_bridge";

    static final String CGROUP_AUTO = "auto";
    static final String CGROUP_V2 = "v2";
    static final String CGROUP_V1 = "v1";

    static final String DOCKER_HOST_ONLY = "host";
    static final String DOCKER_AUTO_BRIDGE = "auto";
    static final String DOCKER_NATIVE_NFT_BRIDGE = "native_nft";
    static final String DOCKER_IPTABLES_NFT_BRIDGE = "iptables_nft";
    static final String DOCKER_LEGACY_BRIDGE = "legacy";

    static final String USB_PASSTHROUGH_OFF = "off";
    static final String USB_PASSTHROUGH_DIRECT = "direct";
    static final String USB_PASSTHROUGH_EXCLUSIVE = "exclusive";

    private BfuPreferences() {}

    static Context deviceProtectedContext(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            return context.createDeviceProtectedStorageContext();
        }
        return context;
    }

    private static SharedPreferences get(Context context) {
        return deviceProtectedContext(context)
                .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    }

    static boolean isEnabled(Context context) {
        return get(context).getBoolean(KEY_ENABLED, false);
    }

    static boolean allowCeReadableBfu(Context context) {
        return get(context).getBoolean(KEY_ALLOW_CE_READABLE_BFU, false);
    }

    static String cgroupPolicy(Context context) {
        return validatedCgroupPolicy(get(context).getString(
                KEY_CGROUP_POLICY, CGROUP_AUTO));
    }

    static String dockerNetworkPolicy(Context context) {
        return validatedDockerNetworkPolicy(get(context).getString(
                KEY_DOCKER_NETWORK_POLICY, DOCKER_HOST_ONLY));
    }

    static boolean dockerHostIpcCompatibility(Context context) {
        // Creating a private IPC namespace panics the target kernel, so host
        // IPC is the safe default rather than an opt-in compatibility switch.
        return get(context).getBoolean(KEY_DOCKER_HOST_IPC_COMPATIBILITY, true);
    }

    static String usbPassthroughMode(Context context) {
        SharedPreferences preferences = get(context);
        String stored = preferences.getString(KEY_USB_PASSTHROUGH_MODE, null);
        if (stored == null && preferences.getBoolean(KEY_SHARE_HOST_USB_LEGACY, false)) {
            return USB_PASSTHROUGH_DIRECT;
        }
        return validatedUsbPassthroughMode(stored);
    }

    static String usbExclusiveDeviceIds(Context context) {
        String stored = get(context).getString(KEY_USB_EXCLUSIVE_DEVICE_IDS, "");
        try {
            return normalizeUsbExclusiveDeviceIds(stored);
        } catch (IllegalArgumentException ignored) {
            return "";
        }
    }

    static boolean hardwareCodecBridge(Context context) {
        return get(context).getBoolean(KEY_HARDWARE_CODEC_BRIDGE, false);
    }

    static void save(Context context, boolean enabled, boolean allowCeReadableBfu,
                     String cgroupPolicy, String dockerNetworkPolicy,
                     boolean dockerHostIpcCompatibility,
                     String usbPassthroughMode, String usbExclusiveDeviceIds,
                     boolean hardwareCodecBridge) {
        String validatedUsbMode = validatedUsbPassthroughMode(usbPassthroughMode);
        String normalizedUsbIds = normalizeUsbExclusiveDeviceIds(
                usbExclusiveDeviceIds);
        if (USB_PASSTHROUGH_EXCLUSIVE.equals(validatedUsbMode)
                && normalizedUsbIds.isEmpty()) {
            throw new IllegalArgumentException(
                    "Exclusive USB passthrough requires at least one VID:PID");
        }
        boolean saved = get(context).edit()
                .putBoolean(KEY_ENABLED, enabled)
                .putBoolean(KEY_ALLOW_CE_READABLE_BFU, allowCeReadableBfu)
                .putString(KEY_CGROUP_POLICY, validatedCgroupPolicy(cgroupPolicy))
                .putString(KEY_DOCKER_NETWORK_POLICY,
                        validatedDockerNetworkPolicy(dockerNetworkPolicy))
                .putBoolean(KEY_DOCKER_HOST_IPC_COMPATIBILITY,
                        dockerHostIpcCompatibility)
                .putString(KEY_USB_PASSTHROUGH_MODE, validatedUsbMode)
                .putString(KEY_USB_EXCLUSIVE_DEVICE_IDS, normalizedUsbIds)
                .putBoolean(KEY_HARDWARE_CODEC_BRIDGE, hardwareCodecBridge)
                .remove(KEY_SHARE_HOST_USB_LEGACY)
                .commit();
        if (!saved) throw new IllegalStateException("Failed to save BFU settings");
    }

    private static String validatedCgroupPolicy(String value) {
        if (CGROUP_V2.equals(value) || CGROUP_V1.equals(value)) return value;
        return CGROUP_AUTO;
    }

    private static String validatedDockerNetworkPolicy(String value) {
        if (DOCKER_AUTO_BRIDGE.equals(value) || DOCKER_NATIVE_NFT_BRIDGE.equals(value)
                || DOCKER_IPTABLES_NFT_BRIDGE.equals(value)
                || DOCKER_LEGACY_BRIDGE.equals(value)) {
            return value;
        }
        return DOCKER_HOST_ONLY;
    }

    private static String validatedUsbPassthroughMode(String value) {
        if (USB_PASSTHROUGH_DIRECT.equals(value)
                || USB_PASSTHROUGH_EXCLUSIVE.equals(value)) {
            return value;
        }
        return USB_PASSTHROUGH_OFF;
    }

    static String normalizeUsbExclusiveDeviceIds(String value) {
        if (value == null || value.trim().isEmpty()) return "";
        if (value.length() > 512) {
            throw new IllegalArgumentException("USB VID:PID list is too long");
        }
        Set<String> normalized = new LinkedHashSet<>();
        String[] entries = value.trim().split("[,\\s]+");
        for (String entry : entries) {
            if (!entry.matches("(?i)[0-9a-f]{4}:[0-9a-f]{4}")) {
                throw new IllegalArgumentException("Invalid USB VID:PID: " + entry);
            }
            normalized.add(entry.toLowerCase(Locale.US));
            if (normalized.size() > 32) {
                throw new IllegalArgumentException("Too many USB VID:PID entries");
            }
        }
        StringBuilder result = new StringBuilder();
        for (String entry : normalized) {
            if (result.length() > 0) result.append(',');
            result.append(entry);
        }
        return result.toString();
    }
}
