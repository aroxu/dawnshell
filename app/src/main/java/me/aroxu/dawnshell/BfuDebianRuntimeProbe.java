package me.aroxu.dawnshell;

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

/** Proves namespace isolation, private /proc, and Debian chroot execution during BFU. */
final class BfuDebianRuntimeProbe {

    private static final long PROBE_TIMEOUT_MS = 35_000L;
    private static final String SUCCESS_MARKER = "BFU_DEBIAN_NAMESPACE_OK";
    private static final String LOG_FILE = "bfu-debian-runtime.log";

    static final class Result {
        final boolean successful;
        final String command;
        final int exitCode;
        final boolean timedOut;
        final boolean userUnlockedBefore;
        final boolean userUnlockedAfter;
        final String output;

        Result(boolean successful, String command, int exitCode, boolean timedOut,
               boolean userUnlockedBefore, boolean userUnlockedAfter, String output) {
            this.successful = successful;
            this.command = command;
            this.exitCode = exitCode;
            this.timedOut = timedOut;
            this.userUnlockedBefore = userUnlockedBefore;
            this.userUnlockedAfter = userUnlockedAfter;
            this.output = output;
        }

        String summary() {
            return "rootfs=" + BfuRootfsProbe.ROOTFS_PATH
                    + " command=" + command
                    + " exit=" + exitCode
                    + " timeout=" + timedOut
                    + " namespace_chroot=" + successful
                    + " user_unlocked_before=" + userUnlockedBefore
                    + " user_unlocked_after=" + userUnlockedAfter
                    + " output=" + output;
        }

        boolean succeededDuringBfu() {
            return successful && !userUnlockedBefore && !userUnlockedAfter;
        }
    }

    private BfuDebianRuntimeProbe() {}

    static Result run(Context context, BfuRuntime.Layout layout)
            throws IOException, InterruptedException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        boolean userUnlockedBefore = isUserUnlocked(context);
        String shellCommand = BfuSu.shellQuote(layout.namespaceProbeBinary.getAbsolutePath())
                + " probe " + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH);
        BfuSu.Result commandResult = BfuSu.run(shellCommand, PROBE_TIMEOUT_MS);
        boolean userUnlockedAfter = isUserUnlocked(context);
        boolean successful = commandResult.exitedSuccessfully()
                && commandResult.output.contains(SUCCESS_MARKER);
        Result result = new Result(successful, commandResult.command,
                commandResult.exitCode, commandResult.timedOut, userUnlockedBefore,
                userUnlockedAfter, commandResult.output);
        appendPersistentResult(deContext, result);
        return result;
    }

    static String readLastPersistentResult(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File log = new File(deContext.getFilesDir(), LOG_FILE);
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
        File log = new File(deContext.getFilesDir(), LOG_FILE);
        String line = "DEBIAN_RUNTIME_PROBE " + System.currentTimeMillis() + " "
                + result.summary() + "\n";
        try (FileOutputStream output = new FileOutputStream(log, true)) {
            output.write(line.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }
}
