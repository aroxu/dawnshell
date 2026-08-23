package me.aroxu.dawnshell;

import android.content.Context;
import android.util.Log;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/** AFU-only, explicit Docker network compatibility policy operation. */
final class DockerNetworkProvisioner {

    private static final String TAG = "DawnShell";
    private static final String LOG_FILE = "docker-network-policy.log";
    private static final String STATUS_FILE = "docker-network-policy.status";
    private static final int MAX_TAIL_BYTES = 48 * 1024;
    private static final Object FILE_LOCK = new Object();

    private DockerNetworkProvisioner() {}

    static boolean apply(Context context, BfuRuntime.Layout layout, String policy) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        LogSink log = null;
        Process process = null;
        try {
            String validated = validatePolicy(policy);
            log = new LogSink(logFile(deContext));
            log.line("============================================================");
            log.line("STAGE: Applying Docker network policy requested=" + validated);
            writeStatus(deContext, "RUNNING requested=" + validated);

            String command = "/system/bin/sh "
                    + BfuSu.shellQuote(
                    layout.dockerNetworkConfiguratorScript.getAbsolutePath())
                    + " " + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH)
                    + " " + BfuSu.shellQuote(layout.root.getAbsolutePath())
                    + " " + BfuSu.shellQuote(validated)
                    + " " + BfuSu.shellQuote(
                    layout.architecture.debianArchitecture);
            BfuSu.StartedProcess started = BfuSu.start(command);
            process = started.process;
            log.line("Magisk command accepted by " + started.command);

            String childError = null;
            String resolvedOutcome = null;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    String clean = sanitizeChildLine(line);
                    log.line("root: " + clean);
                    if (clean.startsWith("ERROR:")) childError = clean;
                    if (clean.startsWith("DOCKER_POLICY_SUCCEEDED:")
                            && clean.contains("resolved_backend=")) {
                        resolvedOutcome = clean.substring(
                                "DOCKER_POLICY_SUCCEEDED:".length()).trim();
                    }
                }
            }
            int exitCode = process.waitFor();
            process = null;
            if (exitCode != 0) {
                String reason = "Docker policy helper exited with status " + exitCode;
                if (childError != null) reason += ": " + childError;
                throw new IOException(reason);
            }

            log.line("Docker network policy completed successfully");
            writeStatus(deContext, "SUCCEEDED "
                    + (resolvedOutcome == null
                    ? "requested=" + validated : resolvedOutcome));
            return true;
        } catch (InterruptedException e) {
            if (process != null) process.destroy();
            Thread.currentThread().interrupt();
            recordFailure(deContext, log, "Docker policy interrupted");
            return false;
        } catch (IOException | RuntimeException e) {
            if (process != null) process.destroy();
            recordFailure(deContext, log, BfuSu.sanitize(e.getMessage()));
            Log.e(TAG, "Docker network policy failed", e);
            return false;
        } finally {
            if (log != null) {
                try {
                    log.close();
                } catch (IOException e) {
                    Log.w(TAG, "Failed to close Docker policy log", e);
                }
            }
        }
    }

    static void recordQueued(Context context, String policy) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        String message = "Docker policy queued: requested=" + validatePolicy(policy);
        try (LogSink log = new LogSink(logFile(deContext))) {
            log.line("QUEUED: " + message);
            writeStatus(deContext, "QUEUED " + message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist queued Docker policy", e);
        }
    }

    static void recordRejected(Context context, String reason) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        String clean = BfuSu.sanitize(reason);
        try (LogSink log = new LogSink(logFile(deContext))) {
            log.line("REQUEST_REJECTED: " + clean);
            writeStatus(deContext, "REJECTED " + clean);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist rejected Docker policy", e);
        }
    }

    static String readStatus(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File file = new File(deContext.getFilesDir(), STATUS_FILE);
        if (!file.isFile()) return "";
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[512];
            int count;
            while (output.size() < 4096
                    && (count = input.read(buffer, 0,
                    Math.min(buffer.length, 4096 - output.size()))) >= 0) {
                output.write(buffer, 0, count);
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8).trim();
        }
    }

    static String readLogTail(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File file = logFile(deContext);
        if (!file.isFile()) return "";
        synchronized (FILE_LOCK) {
            try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
                long length = input.length();
                long start = Math.max(0L, length - MAX_TAIL_BYTES);
                input.seek(start);
                byte[] bytes = new byte[(int) (length - start)];
                input.readFully(bytes);
                int offset = 0;
                if (start > 0L) {
                    while (offset < bytes.length && bytes[offset] != '\n') offset++;
                    if (offset < bytes.length) offset++;
                }
                String value = new String(bytes, offset, bytes.length - offset,
                        StandardCharsets.UTF_8);
                return start > 0L ? "… earlier log omitted …\n" + value : value;
            }
        }
    }

    private static String validatePolicy(String policy) {
        if (BfuPreferences.DOCKER_AUTO_BRIDGE.equals(policy)
                || BfuPreferences.DOCKER_NATIVE_NFT_BRIDGE.equals(policy)
                || BfuPreferences.DOCKER_IPTABLES_NFT_BRIDGE.equals(policy)
                || BfuPreferences.DOCKER_LEGACY_BRIDGE.equals(policy)) {
            return policy;
        }
        return BfuPreferences.DOCKER_HOST_ONLY;
    }

    private static void recordFailure(Context deContext, LogSink log, String reason) {
        String message = reason == null || reason.isEmpty() ? "unknown failure" : reason;
        try {
            if (log != null) log.line("FAILED: " + message);
            writeStatus(deContext, "FAILED " + message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist Docker policy failure", e);
        }
    }

    private static void writeStatus(Context deContext, String status) throws IOException {
        File destination = new File(deContext.getFilesDir(), STATUS_FILE);
        File temporary = new File(deContext.getFilesDir(), STATUS_FILE + ".new");
        String contents = System.currentTimeMillis() + " " + status + "\n";
        synchronized (FILE_LOCK) {
            try (FileOutputStream output = new FileOutputStream(temporary, false)) {
                output.write(contents.getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            setOwnerOnly(temporary);
            if (destination.exists() && !destination.delete()) {
                throw new IOException("cannot replace Docker policy status");
            }
            if (!temporary.renameTo(destination)) {
                throw new IOException("cannot publish Docker policy status");
            }
            setOwnerOnly(destination);
        }
    }

    private static File logFile(Context deContext) {
        return new File(deContext.getFilesDir(), LOG_FILE);
    }

    private static String sanitizeChildLine(String line) {
        String clean = line == null ? "" : line.replace('\0', ' ')
                .replace('\r', ' ').replace('\n', ' ');
        return clean.length() <= 8192 ? clean : clean.substring(0, 8192) + "…";
    }

    private static String utcTimestamp() {
        SimpleDateFormat format = new SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setOwnerOnly(File file) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
    }

    private static final class LogSink implements Closeable {
        private final FileOutputStream output;

        LogSink(File file) throws IOException {
            output = new FileOutputStream(file, true);
            setOwnerOnly(file);
        }

        void line(String value) throws IOException {
            String line = "[" + utcTimestamp() + "] "
                    + sanitizeChildLine(value) + "\n";
            synchronized (FILE_LOCK) {
                output.write(line.getBytes(StandardCharsets.UTF_8));
                output.flush();
                output.getFD().sync();
            }
        }

        @Override
        public void close() throws IOException {
            output.close();
        }
    }
}
