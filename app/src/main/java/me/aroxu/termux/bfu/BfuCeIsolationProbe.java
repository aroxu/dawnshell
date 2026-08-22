package me.aroxu.termux.bfu;

import android.annotation.SuppressLint;
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

/** Fail-closed proof that this app's Credential Encrypted data is unavailable in BFU. */
@SuppressLint("SdCardPath") // Deliberately probes the app's two canonical CE aliases.
final class BfuCeIsolationProbe {

    private static final long PROBE_TIMEOUT_MS = 15_000L;
    private static final String LOG_FILE = "bfu-ce-isolation.log";
    private static final String RECEIPT_FILE = "bfu-ce-sentinel.provisioned";
    private static final String SUCCESS_MARKER = "BFU_APP_CE_ISOLATED";
    private static final String SENTINEL_VALUE = "TERMUX_BFU_CE_SENTINEL_V1";
    private static final String SENTINEL_FILE_NAME = "termux-bfu-ce-sentinel";
    private static final String SENTINEL_PATH =
            "/data/user/0/me.aroxu.termux.bfu/files/termux-bfu-ce-sentinel";
    private static final String PROBE =
            "for path in " + SENTINEL_PATH + " "
                    + "/data/data/me.aroxu.termux.bfu/files/termux-bfu-ce-sentinel; do "
                    + "value=$(/system/bin/cat \"$path\" 2>/dev/null) || continue; "
                    + "if [ \"$value\" = " + SENTINEL_VALUE + " ]; then "
                    + "echo BFU_APP_CE_CONTENT_ACCESSIBLE path=\"$path\"; exit 41; fi; "
                    + "done; echo BFU_APP_CE_ISOLATED sentinel_unreadable=true";

    static final class Result {
        final boolean isolated;
        final String command;
        final int exitCode;
        final boolean timedOut;
        final boolean userUnlockedBefore;
        final boolean userUnlockedAfter;
        final String output;

        Result(boolean isolated, String command, int exitCode, boolean timedOut,
               boolean userUnlockedBefore, boolean userUnlockedAfter, String output) {
            this.isolated = isolated;
            this.command = command;
            this.exitCode = exitCode;
            this.timedOut = timedOut;
            this.userUnlockedBefore = userUnlockedBefore;
            this.userUnlockedAfter = userUnlockedAfter;
            this.output = output;
        }

        String summary() {
            return "command=" + command
                    + " exit=" + exitCode
                    + " timeout=" + timedOut
                    + " ce_isolated=" + isolated
                    + " user_unlocked_before=" + userUnlockedBefore
                    + " user_unlocked_after=" + userUnlockedAfter
                    + " output=" + output;
        }

        boolean succeededDuringBfu() {
            return isolated && !userUnlockedBefore && !userUnlockedAfter;
        }

        boolean contentAccessibleDuringBfu() {
            return !timedOut && exitCode == 41
                    && !userUnlockedBefore && !userUnlockedAfter
                    && output.contains("BFU_APP_CE_CONTENT_ACCESSIBLE");
        }
    }

    private BfuCeIsolationProbe() {}

    static void provisionSentinel(Context context) throws IOException {
        if (!isUserUnlocked(context)) {
            throw new IOException("Cannot provision the CE sentinel before first unlock");
        }

        writeSyncedFile(new File(context.getFilesDir(), SENTINEL_FILE_NAME),
                SENTINEL_VALUE + "\n");

        Context deContext = BfuPreferences.deviceProtectedContext(context);
        writeSyncedFile(new File(deContext.getFilesDir(), RECEIPT_FILE),
                SENTINEL_VALUE + "\n");
    }

    static Result run(Context context) throws IOException, InterruptedException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        boolean userUnlockedBefore = isUserUnlocked(context);
        File receipt = new File(deContext.getFilesDir(), RECEIPT_FILE);
        if (!hasExpectedValue(receipt)) {
            Result result = new Result(false, "none", -3, false,
                    userUnlockedBefore, isUserUnlocked(context),
                    "TERMUX_CE_SENTINEL_NOT_PROVISIONED");
            appendPersistentResult(deContext, result);
            return result;
        }
        // Probe as this standalone app's UID. Running this through Magisk su
        // changes the SELinux and mount context and can report the opposite of
        // what the Termux UID can actually read on some ROMs.
        BfuSu.Result commandResult = BfuSu.runDirectShell(PROBE, PROBE_TIMEOUT_MS);
        boolean userUnlockedAfter = isUserUnlocked(context);
        boolean isolated = commandResult.exitedSuccessfully()
                && commandResult.output.contains(SUCCESS_MARKER)
                && !commandResult.output.contains("BFU_APP_CE_CONTENT_ACCESSIBLE");
        Result result = new Result(isolated, commandResult.command,
                commandResult.exitCode, commandResult.timedOut, userUnlockedBefore,
                userUnlockedAfter, commandResult.output);
        appendPersistentResult(deContext, result);
        return result;
    }

    private static boolean hasExpectedValue(File file) throws IOException {
        if (!file.isFile()) return false;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(file), StandardCharsets.UTF_8))) {
            return SENTINEL_VALUE.equals(reader.readLine());
        }
    }

    private static void writeSyncedFile(File file, String value) throws IOException {
        File temporary = new File(file.getParentFile(), file.getName() + ".new");
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        if (file.exists() && !file.delete()) {
            throw new IOException("Failed to replace CE isolation sentinel");
        }
        if (!temporary.renameTo(file)) {
            throw new IOException("Failed to publish CE isolation sentinel");
        }
        // The marker is deliberately non-secret, but keep it private to this app UID.
        //noinspection ResultOfMethodCallIgnored
        file.setReadable(false, false);
        //noinspection ResultOfMethodCallIgnored
        file.setWritable(false, false);
        //noinspection ResultOfMethodCallIgnored
        file.setReadable(true, true);
        //noinspection ResultOfMethodCallIgnored
        file.setWritable(true, true);
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
        UserManager userManager = (UserManager) context.getSystemService(
                Context.USER_SERVICE);
        return userManager != null && userManager.isUserUnlocked();
    }

    private static void appendPersistentResult(Context deContext, Result result)
            throws IOException {
        File log = new File(deContext.getFilesDir(), LOG_FILE);
        String line = "CE_ISOLATION_PROBE " + System.currentTimeMillis() + " "
                + result.summary() + "\n";
        try (FileOutputStream output = new FileOutputStream(log, true)) {
            output.write(line.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }
}
