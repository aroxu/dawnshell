package me.aroxu.dawnshell;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.UserManager;
import android.util.Log;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

public class BootReceiver extends BroadcastReceiver {

    private static final String TAG = "DawnShell";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        if (Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action)) {
            Log.i(TAG, "LOCKED_BOOT_COMPLETED received");
            appendLockedBootMarker(context);
            recordPersistentEvent(context, "LOCKED_BOOT_COMPLETED received");
            if (BfuPreferences.isEnabled(context)) {
                startBfuEnvironment(context);
            } else {
                Log.i(TAG, "BFU mode is disabled");
                // The codec bridge is independent of BFU Debian, so it must
                // still come up. Otherwise a Debian shell can only reach the
                // hardware codec after someone opens the app by hand.
                startHardwareCodecBridge(context, true);
            }
            return;
        }

        if (Intent.ACTION_BOOT_COMPLETED.equals(action)) {
            Log.i(TAG, "BOOT_COMPLETED received");
            boolean unlocked = isUserUnlocked(context);
            if (BfuPreferences.isEnabled(context) && !unlocked) {
                startBfuEnvironment(context);
                return;
            }
            // A device that boots straight into an unlocked user never sees
            // LOCKED_BOOT_COMPLETED handling reach the bridge, so start it
            // here as well. Both paths are idempotent.
            startHardwareCodecBridge(context, !unlocked);
        }
    }

    private static void startHardwareCodecBridge(Context context,
                                                 boolean bootRetry) {
        if (!BfuPreferences.hardwareCodecBridge(context)) {
            Log.i(TAG, "Hardware codec bridge is disabled");
            return;
        }
        try {
            HardwareCodecService.ensureStarted(context, bootRetry);
            Log.i(TAG, "Hardware codec bridge requested at boot retry=" + bootRetry);
        } catch (RuntimeException e) {
            // A foreground-service start can be refused while the device is
            // still settling; the retry schedule inside the service recovers.
            Log.w(TAG, "Could not start the hardware codec bridge at boot", e);
        }
    }

    private static void appendLockedBootMarker(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;

        Context deContext = context.createDeviceProtectedStorageContext();
        File marker = new File(deContext.getFilesDir(), "bfu-boot.log");
        try (FileWriter writer = new FileWriter(marker, true)) {
            writer.write("LOCKED_BOOT_COMPLETED " + System.currentTimeMillis() + "\n");
            Log.i(TAG, "DE locked boot marker appended: " + marker);
        } catch (IOException e) {
            Log.e(TAG, "Failed to append DE locked boot marker: " + marker, e);
        }
    }

    private static void startBfuEnvironment(Context context) {
        Intent serviceIntent = new Intent(context, BfuBootService.class)
                .setAction(BfuBootService.ACTION_START);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent);
            } else {
                context.startService(serviceIntent);
            }
        } catch (RuntimeException e) {
            Log.e(TAG, "Failed to start BFU service", e);
        }
    }

    private static boolean isUserUnlocked(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true;
        UserManager userManager = (UserManager) context.getSystemService(Context.USER_SERVICE);
        return userManager != null && userManager.isUserUnlocked();
    }

    private static void recordPersistentEvent(Context context, String message) {
        try {
            BfuOperationLog.append(context, message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to append persistent BFU event", e);
        }
    }

}
