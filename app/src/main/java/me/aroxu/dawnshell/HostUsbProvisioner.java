package me.aroxu.dawnshell;

import android.content.Context;
import android.util.Log;

import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** Applies AFU host-USB tooling before the lifecycle restart activates policy. */
final class HostUsbProvisioner {

    private static final String TAG = "DawnShell";

    private HostUsbProvisioner() {}

    static boolean apply(Context context, BfuRuntime.Layout layout)
            throws IOException, InterruptedException {
        String mode = BfuPreferences.usbPassthroughMode(context);
        String command = "/system/bin/sh "
                + BfuSu.shellQuote(layout.hostUsbConfiguratorScript.getAbsolutePath())
                + " " + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH)
                + " " + BfuSu.shellQuote(layout.root.getAbsolutePath());
        BfuSu.Result result = BfuSu.run(command, 30_000L);
        String summary = "HOST_USB_TOOLING mode=" + mode
                + " command=" + result.command
                + " exit=" + result.exitCode
                + " timeout=" + result.timedOut
                + " output=" + result.output;
        appendLifecycleLog(layout, summary);
        if (!result.exitedSuccessfully()) {
            Log.e(TAG, summary);
            BfuOperationLog.append(context, "HOST_USB_POLICY_FAILED " + summary);
            return false;
        }
        Log.i(TAG, summary);
        return true;
    }

    private static void appendLifecycleLog(BfuRuntime.Layout layout, String line)
            throws IOException {
        String clean = BfuSu.sanitize(line);
        try (FileOutputStream output = new FileOutputStream(
                layout.lifecycleLog, true)) {
            output.write((clean + "\n").getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }
}
