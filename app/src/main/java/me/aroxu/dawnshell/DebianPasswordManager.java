package me.aroxu.dawnshell;

import android.content.Context;
import android.os.Build;
import android.os.UserManager;

import java.io.File;
import java.nio.charset.StandardCharsets;

/** AFU-only local Debian password updater. Password bytes are never persisted. */
final class DebianPasswordManager {

    private static final String ROOTFS = "/data/local/debian";
    private static final long TIMEOUT_MS = 15_000L;

    static final class Result {
        final String account;
        final String command;
        final int exitCode;
        final boolean timedOut;
        final String output;

        Result(String account, BfuSu.Result result) {
            this.account = account;
            command = result.command;
            exitCode = result.exitCode;
            timedOut = result.timedOut;
            output = result.output;
        }

        boolean succeeded() {
            return !timedOut && exitCode == 0;
        }

        String summary() {
            return "account=" + account + " command=" + command
                    + " exit=" + exitCode + " timeout=" + timedOut
                    + " output=" + output;
        }
    }

    private DebianPasswordManager() {}

    static Result update(Context context, String account, char[] password)
            throws InterruptedException {
        if (!"root".equals(account) && !"debian".equals(account)) {
            throw new IllegalArgumentException("Unsupported Debian account");
        }
        if (!isUserUnlocked(context)) {
            throw new IllegalStateException("Android must be unlocked");
        }
        validatePassword(password);
        requireConfiguredRootfs();

        byte[] input = null;
        try {
            StringBuilder line = new StringBuilder(account.length() + password.length + 2);
            line.append(account).append(':').append(password).append('\n');
            input = line.toString().getBytes(StandardCharsets.UTF_8);
            for (int i = 0; i < line.length(); i++) line.setCharAt(i, '\0');

            BfuSu.Result result = BfuSu.runWithInput(
                    "chroot " + ROOTFS + " /usr/sbin/chpasswd", input, TIMEOUT_MS);
            input = null; // BfuSu wiped the array in its finally block.
            return new Result(account, result);
        } finally {
            if (input != null) java.util.Arrays.fill(input, (byte) 0);
            java.util.Arrays.fill(password, '\0');
        }
    }

    private static void validatePassword(char[] password) {
        if (password == null || password.length < 8 || password.length > 128) {
            throw new IllegalArgumentException(
                    "Password length must be between 8 and 128 characters");
        }
        for (char value : password) {
            if (value == '\0' || value == '\n' || value == '\r' || value == ':') {
                throw new IllegalArgumentException(
                        "Password contains a forbidden control character or colon");
            }
        }
    }

    private static void requireConfiguredRootfs() {
        if (!new File(ROOTFS + "/.dawnshell-systemd-ready").isFile()
                || !new File(ROOTFS + "/usr/sbin/chpasswd").isFile()) {
            throw new IllegalStateException("Debian systemd rootfs is not configured");
        }
    }

    private static boolean isUserUnlocked(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true;
        UserManager userManager = (UserManager) context.getSystemService(
                Context.USER_SERVICE);
        return userManager != null && userManager.isUserUnlocked();
    }
}
