package me.aroxu.termux.bfu;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

final class BfuPreferences {

    private static final String PREFS_NAME = "termux_bfu";
    private static final String KEY_ENABLED = "enabled";
    private static final String KEY_ALLOW_CE_READABLE_BFU =
            "allow_ce_readable_bfu";

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

    static void save(Context context, boolean enabled, boolean allowCeReadableBfu) {
        boolean saved = get(context).edit()
                .putBoolean(KEY_ENABLED, enabled)
                .putBoolean(KEY_ALLOW_CE_READABLE_BFU, allowCeReadableBfu)
                .commit();
        if (!saved) throw new IllegalStateException("Failed to save BFU settings");
    }
}
