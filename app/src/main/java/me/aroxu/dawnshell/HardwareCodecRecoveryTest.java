package me.aroxu.dawnshell;

import android.content.Context;
import android.os.Process;
import android.os.SystemClock;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;

/** Bounded crash-recovery test for DawnShell's own :codec process only. */
final class HardwareCodecRecoveryTest {

    private static final long RECOVERY_TIMEOUT_MS = 30_000L;
    private static final long POLL_INTERVAL_MS = 500L;

    private HardwareCodecRecoveryTest() {}

    static String run(Context context, BfuRuntime.Layout layout)
            throws IOException, InterruptedException {
        if (!layout.codecClientBinary.isFile()
                || !layout.codecClientBinary.canExecute()) {
            throw new IOException("hardware codec client is not provisioned");
        }
        HardwareCodecService.ensureStarted(context, false);
        BrokerHealth before = waitForHealth(context, layout, -1,
                Math.min(10_000L, RECOVERY_TIMEOUT_MS));
        if (before.pid <= 1 || before.pid == Process.myPid()) {
            throw new IOException("refusing to terminate invalid codec PID " + before.pid);
        }
        if (before.activeSessions != 0 || before.activeTranscoders != 0) {
            throw new IOException("codec recovery test requires no active sessions");
        }

        BfuSu.Result killed = killBrokerScoped(context, before.pid);
        if (!killed.exitedSuccessfully()) {
            throw new IOException("could not terminate codec process: "
                    + BfuSu.sanitize(killed.output));
        }

        BrokerHealth after = waitForHealth(context, layout, before.pid,
                RECOVERY_TIMEOUT_MS);
        if (after.activeSessions != 0 || after.activeTranscoders != 0) {
            throw new IOException("recovered codec broker retained stale sessions");
        }
        String summary = "codec_broker_recovery=verified old_pid=" + before.pid
                + " new_pid=" + after.pid + " active_sessions=0";
        HardwareCodecProbe.recordBrokerEvent(context,
                "BROKER_RECOVERY_TEST_PASSED old_pid=" + before.pid
                        + " new_pid=" + after.pid);
        return summary;
    }

    private static BfuSu.Result killBrokerScoped(Context context, int pid)
            throws InterruptedException {
        String expectedName = context.getPackageName() + ":codec";
        String command = "set -eu; "
                + "pid=" + pid + "; "
                + "expected_name=" + BfuSu.shellQuote(expectedName) + "; "
                + "expected_uid=" + Process.myUid() + "; "
                + "actual_name=\"$(tr '\\000' '\\n' < /proc/$pid/cmdline"
                + " | head -n 1)\"; "
                + "set -- $(grep '^Uid:' /proc/$pid/status); actual_uid=${2:-}; "
                + "if [ \"$actual_name\" != \"$expected_name\" ]"
                + " || [ \"$actual_uid\" != \"$expected_uid\" ]; then "
                + "echo \"refusing pid=$pid name=$actual_name uid=$actual_uid\"; "
                + "exit 64; fi; "
                + "kill -9 \"$pid\"";
        return BfuSu.run(command, 5_000L);
    }

    private static BrokerHealth waitForHealth(Context context,
                                               BfuRuntime.Layout layout,
                                               int rejectedPid,
                                               long timeoutMs)
            throws IOException, InterruptedException {
        long deadline = SystemClock.elapsedRealtime() + timeoutMs;
        String lastFailure = "no response";
        int attempt = 0;
        while (SystemClock.elapsedRealtime() < deadline) {
            attempt++;
            if (attempt == 1 || attempt % 4 == 0) {
                try {
                    HardwareCodecService.ensureStarted(context, false);
                } catch (RuntimeException e) {
                    lastFailure = BfuSu.sanitize(e.getMessage());
                }
            }
            String command = BfuSu.shellQuote(
                    layout.codecClientBinary.getAbsolutePath())
                    + " health --format json";
            BfuSu.Result result = BfuSu.runRaw(command, 4_000L);
            if (result.exitedSuccessfully()) {
                try {
                    BrokerHealth health = parseHealth(result.output);
                    if (health.pid > 1 && health.pid != rejectedPid) return health;
                    lastFailure = "broker still has rejected PID " + rejectedPid;
                } catch (IOException e) {
                    lastFailure = e.getMessage();
                }
            } else {
                lastFailure = "exit=" + result.exitCode
                        + " timeout=" + result.timedOut
                        + " output=" + BfuSu.sanitizeTail(result.output);
            }
            Thread.sleep(POLL_INTERVAL_MS);
        }
        throw new IOException("codec broker did not recover within " + timeoutMs
                + " ms: " + BfuSu.sanitizeTail(lastFailure));
    }

    private static BrokerHealth parseHealth(String output) throws IOException {
        int start = output == null ? -1 : output.indexOf('{');
        int end = output == null ? -1 : output.lastIndexOf('}');
        if (start < 0 || end < start) {
            throw new IOException("codec health JSON was not returned");
        }
        try {
            JSONObject value = new JSONObject(output.substring(start, end + 1));
            if (!"listening".equals(value.optString("broker_state"))) {
                throw new IOException("codec broker is not listening");
            }
            return new BrokerHealth(value.getInt("pid"),
                    value.getInt("active_sessions"),
                    value.getInt("active_transcoders"));
        } catch (JSONException e) {
            throw new IOException("invalid codec health JSON", e);
        }
    }

    private static final class BrokerHealth {
        final int pid;
        final int activeSessions;
        final int activeTranscoders;

        BrokerHealth(int pid, int activeSessions, int activeTranscoders) {
            this.pid = pid;
            this.activeSessions = activeSessions;
            this.activeTranscoders = activeTranscoders;
        }
    }
}
