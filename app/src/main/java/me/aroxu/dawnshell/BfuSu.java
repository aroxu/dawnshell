package me.aroxu.dawnshell;

import android.os.Build;
import android.os.SystemClock;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class BfuSu {

    private static final long TERMINATION_GRACE_MS = 1_000L;
    private static final int MAX_OUTPUT_BYTES = 4_096;
    private static final int MAX_RAW_OUTPUT_BYTES = 64 * 1024;
    private static final int EXIT_TIMEOUT = -2;
    private static final int EXIT_NOT_STARTED = -3;

    private static final String[] SU_CANDIDATES = {
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "su"
    };

    static final class Result {
        final String command;
        final int exitCode;
        final boolean timedOut;
        final String output;

        Result(String command, int exitCode, boolean timedOut, String output) {
            this.command = command;
            this.exitCode = exitCode;
            this.timedOut = timedOut;
            this.output = output;
        }

        boolean exitedSuccessfully() {
            return !timedOut && exitCode == 0;
        }
    }

    static final class StartedProcess {
        final String command;
        final Process process;

        StartedProcess(String command, Process process) {
            this.command = command;
            this.process = process;
        }
    }

    private BfuSu() {}

    static Result run(String shellCommand, long timeoutMs) throws InterruptedException {
        if (shellCommand == null || shellCommand.isEmpty()
                || shellCommand.indexOf('\0') >= 0 || timeoutMs <= 0) {
            throw new IllegalArgumentException("Invalid su command or timeout");
        }

        StringBuilder failures = new StringBuilder();
        for (String candidate : SU_CANDIDATES) {
            if (candidate.startsWith("/")) {
                File executable = new File(candidate);
                if (!executable.isFile() || !executable.canExecute()) continue;
            }

            try {
                return runCandidate(candidate, shellCommand, null, timeoutMs,
                        MAX_OUTPUT_BYTES, false, false);
            } catch (IOException e) {
                if (failures.length() > 0) failures.append("; ");
                failures.append(candidate).append(": ").append(sanitize(e.getMessage()));
            }
        }

        String output = failures.length() == 0 ? "no executable su found" : failures.toString();
        return new Result("none", EXIT_NOT_STARTED, false, output);
    }

    static Result runDirectShell(String shellCommand, long timeoutMs)
            throws InterruptedException {
        if (shellCommand == null || shellCommand.isEmpty()
                || shellCommand.indexOf('\0') >= 0 || timeoutMs <= 0) {
            throw new IllegalArgumentException("Invalid shell command or timeout");
        }

        try {
            return runCandidate("/system/bin/sh", shellCommand, null, timeoutMs,
                    MAX_OUTPUT_BYTES, false, false);
        } catch (IOException e) {
            return new Result("/system/bin/sh", EXIT_NOT_STARTED, false,
                    sanitize(e.getMessage()));
        }
    }

    static Result runWithInput(String shellCommand, byte[] input, long timeoutMs)
            throws InterruptedException {
        if (shellCommand == null || shellCommand.isEmpty()
                || shellCommand.indexOf('\0') >= 0 || input == null || timeoutMs <= 0) {
            throw new IllegalArgumentException("Invalid su command, input, or timeout");
        }

        StringBuilder failures = new StringBuilder();
        try {
            for (String candidate : SU_CANDIDATES) {
                if (candidate.startsWith("/")) {
                    File executable = new File(candidate);
                    if (!executable.isFile() || !executable.canExecute()) continue;
                }

                try {
                    return runCandidate(candidate, shellCommand, input, timeoutMs,
                            MAX_OUTPUT_BYTES, false, false);
                } catch (IOException e) {
                    if (failures.length() > 0) failures.append("; ");
                    failures.append(candidate).append(": ").append(sanitize(e.getMessage()));
                }
            }

            String output = failures.length() == 0
                    ? "no executable su found" : failures.toString();
            return new Result("none", EXIT_NOT_STARTED, false, output);
        } finally {
            Arrays.fill(input, (byte) 0);
        }
    }

    /**
     * Runs a bounded root command while preserving line breaks and retaining
     * the newest output. The stream is drained concurrently so a verbose
     * journal command cannot block on a full pipe before it exits.
     */
    static Result runRaw(String shellCommand, long timeoutMs)
            throws InterruptedException {
        if (shellCommand == null || shellCommand.isEmpty()
                || shellCommand.indexOf('\0') >= 0 || timeoutMs <= 0) {
            throw new IllegalArgumentException("Invalid su command or timeout");
        }

        StringBuilder failures = new StringBuilder();
        for (String candidate : SU_CANDIDATES) {
            if (candidate.startsWith("/")) {
                File executable = new File(candidate);
                if (!executable.isFile() || !executable.canExecute()) continue;
            }
            try {
                return runCandidate(candidate, shellCommand, null, timeoutMs,
                        MAX_RAW_OUTPUT_BYTES, true, true);
            } catch (IOException e) {
                if (failures.length() > 0) failures.append("; ");
                failures.append(candidate).append(": ").append(sanitize(e.getMessage()));
            }
        }
        String output = failures.length() == 0
                ? "no executable su found" : failures.toString();
        return new Result("none", EXIT_NOT_STARTED, false, output);
    }

    static StartedProcess start(String shellCommand) throws IOException {
        if (shellCommand == null || shellCommand.isEmpty()
                || shellCommand.indexOf('\0') >= 0) {
            throw new IllegalArgumentException("Invalid su command");
        }

        StringBuilder failures = new StringBuilder();
        for (String candidate : SU_CANDIDATES) {
            if (candidate.startsWith("/")) {
                File executable = new File(candidate);
                if (!executable.isFile() || !executable.canExecute()) continue;
            }

            try {
                ProcessBuilder builder = new ProcessBuilder(candidate, "-c", shellCommand);
                builder.redirectErrorStream(true);
                return new StartedProcess(candidate, builder.start());
            } catch (IOException e) {
                if (failures.length() > 0) failures.append("; ");
                failures.append(candidate).append(": ").append(sanitize(e.getMessage()));
            }
        }

        String message = failures.length() == 0
                ? "no executable su found" : failures.toString();
        throw new IOException(message);
    }

    static String shellQuote(String value) {
        if (value == null || value.indexOf('\0') >= 0) {
            throw new IllegalArgumentException("Invalid shell value");
        }
        return "'" + value.replace("'", "'\"'\"'") + "'";
    }

    static String sanitize(String value) {
        if (value == null || value.isEmpty()) return "(none)";
        String sanitized = value.replace('\r', ' ').replace('\n', ' ').trim();
        if (sanitized.length() > MAX_OUTPUT_BYTES) {
            return sanitized.substring(0, MAX_OUTPUT_BYTES) + "…";
        }
        return sanitized.isEmpty() ? "(none)" : sanitized;
    }

    static String sanitizeTail(String value) {
        if (value == null || value.isEmpty()) return "(none)";
        String sanitized = value.replace('\r', ' ').replace('\n', ' ').trim();
        if (sanitized.length() > MAX_OUTPUT_BYTES) {
            return "…" + sanitized.substring(sanitized.length() - MAX_OUTPUT_BYTES);
        }
        return sanitized.isEmpty() ? "(none)" : sanitized;
    }

    static boolean containsRootUid(String output) {
        return output != null && output.matches("(?s).*(^|\\s)uid=0(?:\\(|\\s|$).*");
    }

    private static Result runCandidate(String command, String shellCommand, byte[] input,
                                       long timeoutMs, int maximumOutputBytes,
                                       boolean preserveLines, boolean retainTail)
            throws IOException, InterruptedException {
        ProcessBuilder builder = new ProcessBuilder(command, "-c", shellCommand);
        builder.redirectErrorStream(true);
        Process process = builder.start();
        OutputCollector collector = new OutputCollector(process.getInputStream(),
                maximumOutputBytes, retainTail);
        Thread collectorThread = new Thread(collector, "DawnShell-su-output");
        collectorThread.setDaemon(true);
        collectorThread.start();

        try (OutputStream standardInput = process.getOutputStream()) {
            if (input != null) standardInput.write(input);
            standardInput.flush();
        } catch (IOException e) {
            process.destroy();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.destroyForcibly();
            }
            closeQuietly(process.getInputStream());
            collectorThread.join(TERMINATION_GRACE_MS);
            throw e;
        }

        Integer exitCode;
        try {
            exitCode = waitForExit(process, timeoutMs);
        } catch (InterruptedException e) {
            process.destroy();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.destroyForcibly();
            }
            closeQuietly(process.getInputStream());
            throw e;
        }

        boolean timedOut = exitCode == null;
        if (timedOut) exitCode = terminate(process);
        finishCollector(process, collectorThread);
        String output = exitCode == null ? "process did not terminate" : collector.output();
        if (output.isEmpty() && collector.failure() != null) {
            output = collector.failure().getMessage();
        }
        output = preserveLines ? cleanRawOutput(output) : sanitize(output);
        return new Result(command, timedOut ? EXIT_TIMEOUT : exitCode,
                timedOut, output);
    }

    private static Integer terminate(Process process) throws InterruptedException {
        process.destroy();
        Integer exitCode = waitForExit(process, TERMINATION_GRACE_MS);
        if (exitCode == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            process.destroyForcibly();
            exitCode = waitForExit(process, TERMINATION_GRACE_MS);
        }
        return exitCode;
    }

    private static Integer waitForExit(Process process, long timeoutMs)
            throws InterruptedException {
        long deadline = SystemClock.elapsedRealtime() + timeoutMs;
        while (SystemClock.elapsedRealtime() < deadline) {
            try {
                return process.exitValue();
            } catch (IllegalThreadStateException ignored) {
                Thread.sleep(100L);
            }
        }
        try {
            return process.exitValue();
        } catch (IllegalThreadStateException ignored) {
            return null;
        }
    }

    private static void finishCollector(Process process, Thread collectorThread)
            throws InterruptedException {
        collectorThread.join(TERMINATION_GRACE_MS);
        if (collectorThread.isAlive()) {
            closeQuietly(process.getInputStream());
            collectorThread.join(TERMINATION_GRACE_MS);
        }
    }

    private static void closeQuietly(InputStream input) {
        try {
            input.close();
        } catch (IOException ignored) {
            // Process teardown is already in progress.
        }
    }

    private static String cleanRawOutput(String value) {
        if (value == null || value.isEmpty()) return "";
        return value.replace('\0', ' ').replace("\r\n", "\n").replace('\r', '\n').trim();
    }

    private static final class OutputCollector implements Runnable {
        private final InputStream input;
        private final byte[] bytes;
        private final boolean retainTail;
        private int start;
        private int length;
        private boolean truncated;
        private IOException failure;

        OutputCollector(InputStream input, int maximumBytes, boolean retainTail) {
            this.input = input;
            this.bytes = new byte[maximumBytes];
            this.retainTail = retainTail;
        }

        @Override
        public void run() {
            byte[] buffer = new byte[1024];
            try (InputStream source = input) {
                int count;
                while ((count = source.read(buffer)) >= 0) append(buffer, count);
            } catch (IOException e) {
                synchronized (this) {
                    failure = e;
                }
            }
        }

        private synchronized void append(byte[] source, int count) {
            if (count <= 0) return;
            if (!retainTail) {
                int copy = Math.min(count, bytes.length - length);
                if (copy > 0) {
                    System.arraycopy(source, 0, bytes, length, copy);
                    length += copy;
                }
                return;
            }
            for (int index = 0; index < count; index++) {
                if (length < bytes.length) {
                    bytes[(start + length) % bytes.length] = source[index];
                    length++;
                } else {
                    bytes[start] = source[index];
                    start = (start + 1) % bytes.length;
                    truncated = true;
                }
            }
        }

        synchronized String output() {
            byte[] output = new byte[length];
            int first = Math.min(length, bytes.length - start);
            System.arraycopy(bytes, start, output, 0, first);
            if (first < length) {
                System.arraycopy(bytes, 0, output, first, length - first);
            }
            int offset = 0;
            if (truncated) {
                while (offset < output.length && output[offset] != '\n') offset++;
                if (offset < output.length) offset++;
            }
            String value = new String(output, offset, output.length - offset,
                    StandardCharsets.UTF_8);
            return truncated ? "… earlier output omitted …\n" + value : value;
        }

        synchronized IOException failure() {
            return failure;
        }
    }
}
