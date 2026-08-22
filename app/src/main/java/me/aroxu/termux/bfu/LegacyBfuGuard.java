package me.aroxu.termux.bfu;

import java.io.IOException;

/** Prevents the standalone app from racing the former com.termux.boot supervisor. */
final class LegacyBfuGuard {

    private static final String LEGACY_ROOT =
            "/data/user_de/0/com.termux.boot/files/bfu";
    private static final long TIMEOUT_MS = 12_000L;

    private LegacyBfuGuard() {}

    static void requireStopped() throws IOException, InterruptedException {
        String helper = LEGACY_ROOT + "/bin/bfu-namespace-probe-arm64";
        String control = LEGACY_ROOT + "/run";
        String preferences = "/data/user_de/0/com.termux.boot/shared_prefs/termux_bfu.xml";
        String command = "if [ -f " + BfuSu.shellQuote(preferences)
                + " ] && grep -Eq 'name=\"enabled\"[^>]*value=\"true\"' "
                + BfuSu.shellQuote(preferences) + "; then "
                + "echo LEGACY_BFU_ENABLED; exit 43; fi; "
                + "if [ -x " + BfuSu.shellQuote(helper) + " ]; then "
                + BfuSu.shellQuote(helper) + " status "
                + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH) + " "
                + BfuSu.shellQuote(control)
                + "; else echo LEGACY_BFU_NOT_INSTALLED; fi";
        BfuSu.Result result = BfuSu.run(command, TIMEOUT_MS);
        if (result.output.contains("LEGACY_BFU_ENABLED")) {
            throw new IOException(
                    "Disable Direct Boot in legacy com.termux.boot and save first");
        }
        if (result.output.contains("BFU_DEBIAN_RUNNING")) {
            throw new IOException(
                    "Legacy com.termux.boot Debian is still running; stop and disable it first");
        }
        if (!result.exitedSuccessfully()
                && !result.output.contains("BFU_DEBIAN_STOPPED")) {
            throw new IOException("Could not verify legacy BFU state: " + result.output);
        }
    }
}
