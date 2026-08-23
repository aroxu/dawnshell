package me.aroxu.dawnshell;

import android.os.Build;
import android.os.SystemClock;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class BfuSu {

    private static final long TERMINATION_GRACE_MS = 1_000L;
    private static final int MAX_OUTPUT_BYTES = 4_096;
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
                return runCandidate(candidate, shellCommand, timeoutMs);
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
            return runCandidate("/system/bin/sh", shellCommand, timeoutMs);
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
                    return runCandidate(candidate, shellCommand, input, timeoutMs);
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

    static boolean containsRootUid(String output) {
        return output != null && output.matches("(?s).*(^|\\s)uid=0(?:\\(|\\s|$).*");
    }

    private static Result runCandidate(String command, String shellCommand, long timeoutMs)
            throws IOException, InterruptedException {
        return runCandidate(command, shellCommand, null, timeoutMs);
    }

    private static Result runCandidate(String command, String shellCommand, byte[] input,
                                       long timeoutMs)
            throws IOException, InterruptedException {
        ProcessBuilder builder = new ProcessBuilder(command, "-c", shellCommand);
        builder.redirectErrorStream(true);
        Process process = builder.start();

        try (OutputStream standardInput = process.getOutputStream()) {
            if (input != null) standardInput.write(input);
            standardInput.flush();
        }

        Integer exitCode;
        try {
            exitCode = waitForExit(process, timeoutMs);
        } catch (InterruptedException e) {
            process.destroy();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.destroyForcibly();
            }
            throw e;
        }

        boolean timedOut = exitCode == null;
        if (timedOut) exitCode = terminate(process);
        String output = exitCode == null ? "process did not terminate" : readOutput(process);
        return new Result(command, timedOut ? EXIT_TIMEOUT : exitCode,
                timedOut, sanitize(output));
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

    private static String readOutput(Process process) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (InputStream input = process.getInputStream()) {
            byte[] buffer = new byte[512];
            int count;
            while (output.size() < MAX_OUTPUT_BYTES
                    && (count = input.read(buffer, 0,
                    Math.min(buffer.length, MAX_OUTPUT_BYTES - output.size()))) >= 0) {
                output.write(buffer, 0, count);
            }
        }
        return new String(output.toByteArray(), StandardCharsets.UTF_8);
    }
}
