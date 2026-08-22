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

final class BfuRootProbe {

    private static final long PROBE_TIMEOUT_MS = 15_000L;

    static final class Result {
        final boolean root;
        final String command;
        final int exitCode;
        final boolean timedOut;
        final boolean userUnlockedBefore;
        final boolean userUnlockedAfter;
        final String output;

        Result(boolean root, String command, int exitCode, boolean timedOut,
               boolean userUnlockedBefore, boolean userUnlockedAfter, String output) {
            this.root = root;
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
                    + " root=" + root
                    + " user_unlocked_before=" + userUnlockedBefore
                    + " user_unlocked_after=" + userUnlockedAfter
                    + " output=" + output;
        }

        boolean succeededDuringBfu() {
            return root && !userUnlockedBefore && !userUnlockedAfter;
        }
    }

    private BfuRootProbe() {}

    static Result run(Context context) throws IOException, InterruptedException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        boolean userUnlockedBefore = isUserUnlocked(context);
        BfuSu.Result commandResult = BfuSu.run("id", PROBE_TIMEOUT_MS);
        boolean userUnlockedAfter = isUserUnlocked(context);
        boolean root = commandResult.exitedSuccessfully()
                && BfuSu.containsRootUid(commandResult.output);
        Result result = new Result(root, commandResult.command,
                commandResult.exitCode, commandResult.timedOut, userUnlockedBefore,
                userUnlockedAfter, commandResult.output);
        appendPersistentResult(deContext, result);
        return result;
    }

    static String readLastPersistentResult(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File log = new File(deContext.getFilesDir(), "bfu-root.log");
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
        File log = new File(deContext.getFilesDir(), "bfu-root.log");
        String line = "ROOT_PROBE " + System.currentTimeMillis() + " "
                + result.summary() + "\n";
        try (FileOutputStream output = new FileOutputStream(log, true)) {
            output.write(line.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }

}
