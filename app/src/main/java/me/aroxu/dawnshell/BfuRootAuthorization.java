package me.aroxu.dawnshell;

import android.content.Context;
import android.os.Build;
import android.os.Process;
import android.os.UserManager;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/**
 * Requests Magisk root while the user can interact with its authorization UI.
 *
 * <p>This is deliberately separate from {@link BfuRootProbe}. An AFU grant is
 * useful setup state, but it can never be recorded as evidence that root worked
 * before first unlock.</p>
 */
final class BfuRootAuthorization {

    private static final long AUTHORIZATION_TIMEOUT_MS = 120_000L;
    private static final String LOG_FILE = "bfu-root-authorization.log";

    static final class Result {
        final boolean root;
        final int appUid;
        final String command;
        final int exitCode;
        final boolean timedOut;
        final boolean userUnlockedBefore;
        final boolean userUnlockedAfter;
        final String output;

        Result(boolean root, int appUid, String command, int exitCode, boolean timedOut,
               boolean userUnlockedBefore, boolean userUnlockedAfter, String output) {
            this.root = root;
            this.appUid = appUid;
            this.command = command;
            this.exitCode = exitCode;
            this.timedOut = timedOut;
            this.userUnlockedBefore = userUnlockedBefore;
            this.userUnlockedAfter = userUnlockedAfter;
            this.output = output;
        }

        String summary() {
            return "app_uid=" + appUid
                    + " command=" + command
                    + " exit=" + exitCode
                    + " timeout=" + timedOut
                    + " root=" + root
                    + " user_unlocked_before=" + userUnlockedBefore
                    + " user_unlocked_after=" + userUnlockedAfter
                    + " output=" + output;
        }

        boolean authorizedWhileUnlocked() {
            return root && userUnlockedBefore && userUnlockedAfter;
        }
    }

    private BfuRootAuthorization() {}

    static Result request(Context context) throws IOException, InterruptedException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        int appUid = Process.myUid();
        boolean userUnlockedBefore = isUserUnlocked(context);
        if (!userUnlockedBefore) {
            throw new IllegalStateException("Android must be unlocked to show Magisk approval UI");
        }

        BfuSu.Result commandResult = BfuSu.run("id", AUTHORIZATION_TIMEOUT_MS);
        boolean userUnlockedAfter = isUserUnlocked(context);
        boolean root = commandResult.exitedSuccessfully()
                && BfuSu.containsRootUid(commandResult.output);
        Result result = new Result(root, appUid, commandResult.command,
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
        String line = "ROOT_AUTHORIZATION " + System.currentTimeMillis() + " "
                + result.summary() + "\n";
        try (FileOutputStream output = new FileOutputStream(log, true)) {
            output.write(line.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }
}
