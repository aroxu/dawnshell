package me.aroxu.dawnshell;

import android.content.Context;
import android.os.SystemClock;
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

/** AFU-only Debian 13 systemd, D-Bus, and OpenSSH configuration task. */
final class DebianSystemProvisioner {

    private static final String TAG = "DawnShell";
    private static final String LOG_FILE = "debian-system-config.log";
    private static final String STATUS_FILE = "debian-system-config.status";
    private static final int MAX_TAIL_BYTES = 48 * 1024;
    private static final int MAX_CHILD_LINE_CHARS = 8 * 1024;
    private static final Object FILE_LOCK = new Object();

    private DebianSystemProvisioner() {}

    static boolean configure(Context context, BfuRuntime.Layout layout) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        LogSink log = null;
        Process process = null;
        try {
            log = new LogSink(logFile(deContext));
            log.line("============================================================");
            updateStage(deContext, log,
                    "Preparing Debian 13 systemd, D-Bus, and OpenSSH configuration");
            log.line("Rootfs: " + BfuRootfsProbe.ROOTFS_PATH);
            log.line("SSH policy: user=debian port=22 public-key-only; Android NIC shared directly");

            if (!layout.authorizedKeys.isFile() || layout.authorizedKeys.length() == 0) {
                throw new IOException("DE authorized_keys is missing or empty");
            }

            updateStage(deContext, log, "Starting root system configurator");
            String command = "/system/bin/sh "
                    + BfuSu.shellQuote(layout.systemdConfiguratorScript.getAbsolutePath())
                    + " " + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH)
                    + " " + BfuSu.shellQuote(layout.root.getAbsolutePath())
                    + " " + BfuSu.shellQuote(layout.authorizedKeys.getAbsolutePath());
            BfuSu.StartedProcess started = BfuSu.start(command);
            process = started.process;
            log.line("Magisk command accepted by " + started.command);

            String childError = null;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    String clean = sanitizeChildLine(line);
                    log.line("root: " + clean);
                    if (clean.startsWith("ERROR:")) childError = clean;
                }
            }

            int exitCode = process.waitFor();
            process = null;
            if (exitCode != 0) {
                String reason = "system configurator exited with status " + exitCode;
                if (childError != null && !childError.isEmpty()) reason += ": " + childError;
                throw new IOException(reason);
            }

            log.line("Debian system configuration completed successfully");
            writeStatus(deContext,
                    "SUCCEEDED Debian 13 systemd + D-Bus + SSH :22 are BFU-ready");
            Log.i(TAG, "Debian systemd and SSH configuration succeeded");
            return true;
        } catch (InterruptedException e) {
            if (process != null) process.destroy();
            Thread.currentThread().interrupt();
            recordFailure(deContext, log, "configuration interrupted");
            return false;
        } catch (IOException | RuntimeException e) {
            if (process != null) process.destroy();
            recordFailure(deContext, log, BfuSu.sanitize(e.getMessage()));
            Log.e(TAG, "Debian system configuration failed", e);
            return false;
        } finally {
            if (log != null) {
                try {
                    log.close();
                } catch (IOException e) {
                    Log.w(TAG, "Failed to close Debian system configuration log", e);
                }
            }
        }
    }

    static void recordRejected(Context context, String reason) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        try (LogSink log = new LogSink(logFile(deContext))) {
            log.line("REQUEST_REJECTED: " + reason);
            writeStatus(deContext, "REJECTED " + reason);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist rejected configuration request", e);
        }
    }

    static void recordQueued(Context context) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        try (LogSink log = new LogSink(logFile(deContext))) {
            String message = "Configuration queued behind BFU service work";
            log.line("QUEUED: " + message);
            writeStatus(deContext, "QUEUED " + message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist queued configuration request", e);
        }
    }

    static void recordMessage(Context context, String message) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        try (LogSink log = new LogSink(logFile(deContext))) {
            log.line(message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to append Debian configuration message", e);
        }
    }

    static String readStatus(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File file = new File(deContext.getFilesDir(), STATUS_FILE);
        if (!file.isFile()) return "";
        byte[] bytes = readAtMost(file, 4 * 1024);
        return new String(bytes, StandardCharsets.UTF_8).trim();
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

    private static void updateStage(Context deContext, LogSink log, String stage)
            throws IOException {
        log.line("STAGE: " + stage);
        writeStatus(deContext, "RUNNING " + stage);
    }

    private static void recordFailure(Context deContext, LogSink log, String reason) {
        String message = reason == null || reason.isEmpty() ? "unknown failure" : reason;
        if (log != null) {
            try {
                log.line("FAILED: " + message);
            } catch (IOException e) {
                Log.e(TAG, "Failed to append Debian configuration failure", e);
            }
        }
        try {
            writeStatus(deContext, "FAILED " + message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist Debian configuration failure", e);
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
                throw new IOException("cannot replace configuration status");
            }
            if (!temporary.renameTo(destination)) {
                throw new IOException("cannot publish configuration status");
            }
            setOwnerOnly(destination);
        }
    }

    private static File logFile(Context context) {
        return new File(context.getFilesDir(), LOG_FILE);
    }

    private static byte[] readAtMost(File file, int maximum) throws IOException {
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[512];
            int count;
            while (output.size() < maximum
                    && (count = input.read(buffer, 0,
                    Math.min(buffer.length, maximum - output.size()))) >= 0) {
                output.write(buffer, 0, count);
            }
            return output.toByteArray();
        }
    }

    private static String sanitizeChildLine(String value) {
        String clean = value.replace('\0', ' ').replace('\r', ' ');
        if (clean.length() > MAX_CHILD_LINE_CHARS) {
            return clean.substring(0, MAX_CHILD_LINE_CHARS) + "…";
        }
        return clean;
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
        private final SimpleDateFormat dateFormat;
        private long lastSyncElapsed;

        LogSink(File file) throws IOException {
            output = new FileOutputStream(file, true);
            dateFormat = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
            dateFormat.setTimeZone(TimeZone.getTimeZone("UTC"));
            lastSyncElapsed = SystemClock.elapsedRealtime();
            setOwnerOnly(file);
        }

        void line(String value) throws IOException {
            String clean = value == null ? "(null)" : value.replace('\0', ' ');
            String line = "[" + dateFormat.format(new Date()) + "] " + clean + "\n";
            synchronized (FILE_LOCK) {
                output.write(line.getBytes(StandardCharsets.UTF_8));
                output.flush();
                long now = SystemClock.elapsedRealtime();
                if (now - lastSyncElapsed >= 1_000L) {
                    output.getFD().sync();
                    lastSyncElapsed = now;
                }
            }
        }

        @Override
        public void close() throws IOException {
            synchronized (FILE_LOCK) {
                try {
                    output.getFD().sync();
                } finally {
                    output.close();
                }
            }
        }
    }
}
