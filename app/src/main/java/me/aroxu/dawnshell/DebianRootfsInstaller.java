package me.aroxu.dawnshell;

import android.content.Context;
import android.os.SystemClock;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

import javax.net.ssl.HttpsURLConnection;

final class DebianRootfsInstaller {

    private static final String TAG = "DawnShell";
    private static final String LOG_FILE = "debian-install.log";
    private static final String STATUS_FILE = "debian-install.status";
    private static final int CONNECT_TIMEOUT_MS = 30_000;
    private static final int READ_TIMEOUT_MS = 60_000;
    private static final int MAX_TAIL_BYTES = 48 * 1024;
    private static final int MAX_CHILD_LINE_CHARS = 8 * 1024;

    private static final Artifact DEBOOTSTRAP = new Artifact(
            "Debian Trixie debootstrap 1.0.141",
            "https://deb.debian.org/debian/pool/main/d/debootstrap/"
                    + "debootstrap_1.0.141.tar.gz",
            "232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b");
    private static final Artifact ARCHIVE_KEYRING = new Artifact(
            "Debian Trixie archive keyring 2025.1",
            "https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/"
                    + "debian-archive-keyring_2025.1_all.deb",
            "9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac");

    private static final Object FILE_LOCK = new Object();

    private DebianRootfsInstaller() {}

    static void install(Context context, BfuRuntime.Layout layout) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        LogSink log = null;
        Process process = null;
        try {
            log = new LogSink(logFile(deContext));
            log.line("============================================================");
            updateStage(deContext, log, "Preparing Debian 13 Trixie arm64 installation");
            log.line("Final target: " + BfuRootfsProbe.ROOTFS_PATH);
            log.line("Termux CE is used only for AFU bootstrap tools; no rootfs file is stored there");

            downloadAndVerify(deContext, log, DEBOOTSTRAP, layout.debootstrapArchive);
            downloadAndVerify(deContext, log, ARCHIVE_KEYRING,
                    layout.archiveKeyringPackage);

            updateStage(deContext, log, "Starting root installer");
            String command = "/system/bin/sh "
                    + BfuSu.shellQuote(layout.rootfsInstallerScript.getAbsolutePath())
                    + " " + BfuSu.shellQuote(layout.debootstrapArchive.getAbsolutePath())
                    + " " + BfuSu.shellQuote(layout.archiveKeyringPackage.getAbsolutePath())
                    + " " + BfuSu.shellQuote(layout.root.getAbsolutePath());
            BfuSu.StartedProcess started = BfuSu.start(command);
            process = started.process;
            log.line("Magisk command accepted by " + started.command);

            String childError = null;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    String sanitized = sanitizeChildLine(line);
                    log.line("root: " + sanitized);
                    if (sanitized.startsWith("ERROR:")) childError = sanitized;
                }
            }

            int exitCode = process.waitFor();
            process = null;
            if (exitCode != 0) {
                String reason = "root installer exited with status " + exitCode;
                if (childError != null && !childError.isEmpty()) {
                    reason += ": " + childError;
                }
                throw new IOException(reason);
            }

            log.line("Debian rootfs installation completed successfully");
            writeStatus(deContext, "SUCCEEDED Debian 13 Trixie rootfs is ready at "
                    + BfuRootfsProbe.ROOTFS_PATH);
            Log.i(TAG, "Debian rootfs installation succeeded");
        } catch (InterruptedException e) {
            if (process != null) process.destroy();
            Thread.currentThread().interrupt();
            recordFailure(deContext, log, "installation interrupted");
        } catch (IOException | RuntimeException e) {
            if (process != null) process.destroy();
            recordFailure(deContext, log, BfuSu.sanitize(e.getMessage()));
            Log.e(TAG, "Debian rootfs installation failed", e);
        } finally {
            if (log != null) {
                try {
                    log.close();
                } catch (IOException e) {
                    Log.w(TAG, "Failed to close Debian installation log", e);
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
            Log.e(TAG, "Failed to persist rejected installation request", e);
        }
    }

    static void recordQueued(Context context) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        try (LogSink log = new LogSink(logFile(deContext))) {
            String message = "Installation queued behind BFU startup checks";
            log.line("QUEUED: " + message);
            writeStatus(deContext, "QUEUED " + message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to persist queued installation request", e);
        }
    }

    static void recordMessage(Context context, String message) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        try (LogSink log = new LogSink(logFile(deContext))) {
            log.line(message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to append Debian installation message", e);
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

    private static void downloadAndVerify(Context deContext, LogSink log,
                                          Artifact artifact, File destination)
            throws IOException {
        updateStage(deContext, log, "Verifying " + artifact.label);
        if (destination.isFile() && artifact.sha256.equals(sha256(destination))) {
            log.line("Using verified cached artifact: " + destination.getName());
            return;
        }

        File temporary = new File(destination.getParentFile(),
                destination.getName() + ".part");
        if (temporary.exists() && !temporary.delete()) {
            throw new IOException("cannot replace partial download " + temporary);
        }

        updateStage(deContext, log, "Downloading " + artifact.label);
        URL url = new URL(artifact.url);
        if (!"https".equalsIgnoreCase(url.getProtocol())
                || !"deb.debian.org".equalsIgnoreCase(url.getHost())) {
            throw new IOException("artifact URL is outside the pinned Debian HTTPS host");
        }

        HttpsURLConnection connection = (HttpsURLConnection) url.openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
        connection.setReadTimeout(READ_TIMEOUT_MS);
        connection.setRequestProperty("User-Agent", "DawnShell/0.8.1");
        int responseCode = connection.getResponseCode();
        if (responseCode != HttpsURLConnection.HTTP_OK) {
            connection.disconnect();
            throw new IOException("Debian download returned HTTP " + responseCode);
        }

        long expectedLength = connection.getContentLength();
        long total = 0L;
        long lastProgressAt = SystemClock.elapsedRealtime();
        MessageDigest digest = newSha256();
        try (InputStream input = new BufferedInputStream(connection.getInputStream());
             FileOutputStream output = new FileOutputStream(temporary, false)) {
            byte[] buffer = new byte[32 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                output.write(buffer, 0, count);
                digest.update(buffer, 0, count);
                total += count;
                long now = SystemClock.elapsedRealtime();
                if (now - lastProgressAt >= 2_000L) {
                    log.line(downloadProgress(total, expectedLength));
                    lastProgressAt = now;
                }
            }
            output.getFD().sync();
        } finally {
            connection.disconnect();
        }

        String actual = hex(digest.digest());
        log.line(downloadProgress(total, expectedLength));
        if (!artifact.sha256.equals(actual)) {
            // A failed integrity check must never leave an artifact eligible for use.
            //noinspection ResultOfMethodCallIgnored
            temporary.delete();
            throw new IOException("SHA-256 mismatch for " + artifact.label
                    + ": expected=" + artifact.sha256 + " actual=" + actual);
        }

        if (destination.exists() && !destination.delete()) {
            throw new IOException("cannot replace unverified cache file " + destination);
        }
        if (!temporary.renameTo(destination)) {
            throw new IOException("cannot install verified cache file " + destination);
        }
        setOwnerOnly(destination);
        log.line("SHA-256 verified: " + actual);
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
            } catch (IOException writeError) {
                Log.e(TAG, "Failed to append Debian installer failure", writeError);
            }
        }
        try {
            writeStatus(deContext, "FAILED " + message);
        } catch (IOException writeError) {
            Log.e(TAG, "Failed to persist Debian installer failure", writeError);
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
                throw new IOException("cannot replace installer status");
            }
            if (!temporary.renameTo(destination)) {
                throw new IOException("cannot publish installer status");
            }
            setOwnerOnly(destination);
        }
    }

    private static File logFile(Context deContext) {
        return new File(deContext.getFilesDir(), LOG_FILE);
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

    private static String sha256(File file) throws IOException {
        MessageDigest digest = newSha256();
        try (InputStream input = new BufferedInputStream(new FileInputStream(file))) {
            byte[] buffer = new byte[32 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) digest.update(buffer, 0, count);
        }
        return hex(digest.digest());
    }

    private static MessageDigest newSha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("Android runtime has no SHA-256", e);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(Locale.US, "%02x", value & 0xff));
        return result.toString();
    }

    private static String downloadProgress(long bytes, long expected) {
        if (expected > 0L) {
            int percent = (int) Math.min(100L, bytes * 100L / expected);
            return "Download progress: " + bytes + "/" + expected + " bytes ("
                    + percent + "%)";
        }
        return "Download progress: " + bytes + " bytes";
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

    private static final class Artifact {
        final String label;
        final String url;
        final String sha256;

        Artifact(String label, String url, String sha256) {
            this.label = label;
            this.url = url;
            this.sha256 = sha256;
        }
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
