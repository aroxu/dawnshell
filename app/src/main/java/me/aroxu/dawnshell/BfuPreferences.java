package me.aroxu.dawnshell;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

final class BfuPreferences {

    private static final String PREFS_NAME = "dawnshell";
    private static final String KEY_ENABLED = "enabled";
    private static final String KEY_ALLOW_CE_READABLE_BFU =
            "allow_ce_readable_bfu";
    private static final String KEY_CGROUP_POLICY = "cgroup_policy";
    private static final String KEY_DOCKER_NETWORK_POLICY = "docker_network_policy";

    static final String CGROUP_AUTO = "auto";
    static final String CGROUP_V2 = "v2";
    static final String CGROUP_V1 = "v1";

    static final String DOCKER_HOST_ONLY = "host";
    static final String DOCKER_AUTO_BRIDGE = "auto";
    static final String DOCKER_NATIVE_NFT_BRIDGE = "native_nft";
    static final String DOCKER_IPTABLES_NFT_BRIDGE = "iptables_nft";
    static final String DOCKER_LEGACY_BRIDGE = "legacy";

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

    static void save(Context context, boolean enabled, boolean allowCeReadableBfu,
                     String cgroupPolicy, String dockerNetworkPolicy) {
        boolean saved = get(context).edit()
                .putBoolean(KEY_ENABLED, enabled)
                .putBoolean(KEY_ALLOW_CE_READABLE_BFU, allowCeReadableBfu)
                .putString(KEY_CGROUP_POLICY, validatedCgroupPolicy(cgroupPolicy))
                .putString(KEY_DOCKER_NETWORK_POLICY,
                        validatedDockerNetworkPolicy(dockerNetworkPolicy))
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
}
