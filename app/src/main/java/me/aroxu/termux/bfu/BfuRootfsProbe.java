package me.aroxu.termux.bfu;

import android.content.Context;
import android.os.Build;
import android.os.UserManager;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

final class BfuRootfsProbe {

    static final String ROOTFS_PATH = "/data/local/debian";

    private static final long PROBE_TIMEOUT_MS = 15_000L;
    private static final String SUCCESS_MARKER =
            "Debian-rootfs-access-ok root=" + ROOTFS_PATH;

    static final class Result {
        final boolean accessible;
        final String rootfs;
        final String command;
        final int exitCode;
        final boolean timedOut;
        final boolean userUnlockedBefore;
        final boolean userUnlockedAfter;
        final String output;

        Result(boolean accessible, String command, int exitCode, boolean timedOut,
               boolean userUnlockedBefore, boolean userUnlockedAfter, String output) {
            this.accessible = accessible;
            this.rootfs = ROOTFS_PATH;
            this.command = command;
            this.exitCode = exitCode;
            this.timedOut = timedOut;
            this.userUnlockedBefore = userUnlockedBefore;
            this.userUnlockedAfter = userUnlockedAfter;
            this.output = output;
        }

        String summary() {
            return "rootfs=" + rootfs
                    + " command=" + command
                    + " exit=" + exitCode
                    + " timeout=" + timedOut
                    + " accessible=" + accessible
                    + " user_unlocked_before=" + userUnlockedBefore
                    + " user_unlocked_after=" + userUnlockedAfter
                    + " output=" + output;
        }

        boolean succeededDuringBfu() {
            return accessible && !userUnlockedBefore && !userUnlockedAfter;
        }
    }

    private BfuRootfsProbe() {}

    static Result run(Context context, BfuRuntime.Layout layout)
            throws IOException, InterruptedException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        boolean userUnlockedBefore = isUserUnlocked(context);
        String command = BfuSu.shellQuote(layout.rootfsProbeScript.getAbsolutePath())
                + " " + BfuSu.shellQuote(ROOTFS_PATH);
        BfuSu.Result commandResult = BfuSu.run(command, PROBE_TIMEOUT_MS);
        boolean userUnlockedAfter = isUserUnlocked(context);
        boolean accessible = commandResult.exitedSuccessfully()
                && commandResult.output.contains(SUCCESS_MARKER);
        Result result = new Result(accessible, commandResult.command,
                commandResult.exitCode, commandResult.timedOut, userUnlockedBefore,
                userUnlockedAfter, commandResult.output);
        appendPersistentResult(deContext, result);
        return result;
    }

    static String readLastPersistentResult(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File log = new File(deContext.getFilesDir(), "bfu-rootfs.log");
        if (!log.isFile()) return "";

        String lastLine = "";
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(log), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (!line.trim().isEmpty()) lastLine = line;
            }
        }
        return lastLine;
    }

    private static boolean isUserUnlocked(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true;
        UserManager userManager = (UserManager) context.getSystemService(Context.USER_SERVICE);
        return userManager != null && userManager.isUserUnlocked();
    }

    private static void appendPersistentResult(Context deContext, Result result)
            throws IOException {
        File log = new File(deContext.getFilesDir(), "bfu-rootfs.log");
        String line = "ROOTFS_PROBE " + System.currentTimeMillis() + " "
                + result.summary() + "\n";
        try (FileOutputStream output = new FileOutputStream(log, true)) {
            output.write(line.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }
}
