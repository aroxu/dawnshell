package me.aroxu.dawnshell;

import android.content.Context;

import java.io.IOException;

/** AFU-only destructive removal of the one fixed Debian rootfs path. */
final class DebianRootfsRemover {

    private static final long REMOVE_TIMEOUT_MS = 120_000L;

    private DebianRootfsRemover() {}

    static void remove(Context context, BfuRuntime.Layout layout)
            throws IOException, InterruptedException {
        BfuOperationLog.append(context,
                "DEBIAN_ROOTFS_REMOVE_STARTED root=/data/local/debian");
        BfuSu.Result presence = BfuSu.run(
                "if [ -e /data/local/debian ]; then echo ROOTFS_PRESENT; "
                        + "else echo ROOTFS_ABSENT; fi", 10_000L);
        if (presence.exitedSuccessfully()
                && presence.output.contains("ROOTFS_ABSENT")) {
            BfuOperationLog.append(context,
                    "DEBIAN_ROOTFS_REMOVE_SUCCEEDED root=/data/local/debian "
                            + "result=already_absent");
            return;
        }
        if (!presence.exitedSuccessfully()
                || !presence.output.contains("ROOTFS_PRESENT")) {
            throw new IOException("Could not verify rootfs presence: " + presence.output);
        }
        if (!DebianLauncher.run(context, layout, DebianLauncher.Operation.STOP,
                "rootfs_removal")) {
            throw new IOException("Could not prove the standalone Debian supervisor stopped");
        }

        String root = BfuRootfsProbe.ROOTFS_PATH;
        String command = "root=" + BfuSu.shellQuote(root) + "; "
                + "if [ ! -e \"$root\" ]; then echo DEBIAN_ROOTFS_ALREADY_ABSENT; exit 0; fi; "
                + "[ ! -L \"$root\" ] || { echo REFUSING_SYMLINK_ROOTFS; exit 41; }; "
                + "resolved=$(cd -P \"$root\" 2>/dev/null && pwd -P) || exit 42; "
                + "[ \"$resolved\" = " + BfuSu.shellQuote(root)
                + " ] || { echo REFUSING_RESOLVED_PATH path=\"$resolved\"; exit 43; }; "
                + "for file in /proc/[0-9]*/comm; do "
                + "[ \"$(cat \"$file\" 2>/dev/null)\" != systemd ] "
                + "|| { echo REFUSING_LIVE_SYSTEMD; exit 44; }; done; "
                + "rm -rf -- \"$root\"; "
                + "[ ! -e \"$root\" ] || { echo ROOTFS_DELETE_FAILED; exit 45; }; "
                + "echo DEBIAN_ROOTFS_REMOVED";
        BfuSu.Result result = BfuSu.run(command, REMOVE_TIMEOUT_MS);
        if (!result.exitedSuccessfully()) {
            BfuOperationLog.append(context,
                    "DEBIAN_ROOTFS_REMOVE_FAILED exit=" + result.exitCode
                            + " timeout=" + result.timedOut
                            + " output=" + result.output);
            throw new IOException("Rootfs remover failed: " + result.output);
        }
        BfuOperationLog.append(context,
                "DEBIAN_ROOTFS_REMOVE_SUCCEEDED root=/data/local/debian result="
                        + result.output);
    }
}
