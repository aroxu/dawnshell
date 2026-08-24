package me.aroxu.dawnshell;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/** Controls the fixed, allow-listed codec soak-test unit inside Debian PID 1. */
final class HardwareCodecLongRun {

    enum Operation { START, STOP, STATUS }

    private static final String STATUS_FILE = "hardware-codec-long-run.status";
    private static final int MAX_STATUS_BYTES = 8 * 1024;

    private HardwareCodecLongRun() {}

    static BfuSu.Result run(Context context, BfuRuntime.Layout layout,
                            Operation operation) throws IOException, InterruptedException {
        String command = namespaceCommand(layout,
                operation.name().toLowerCase(Locale.US));
        BfuSu.Result result = BfuSu.run(command, 25_000L);
        String summary = operation.name()
                + " exit=" + result.exitCode
                + " timeout=" + result.timedOut
                + " output=" + BfuSu.sanitize(result.output);
        writeStatus(context, (result.exitedSuccessfully() ? "SUCCEEDED " : "FAILED ")
                + summary);
        HardwareCodecProbe.recordBrokerEvent(context,
                "LONG_RUN_CONTROL " + summary);
        return result;
    }

    static String readStatus(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File file = new File(deContext.getFilesDir(), STATUS_FILE);
        if (!file.isFile()) return "";
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[512];
            int count;
            while (output.size() < MAX_STATUS_BYTES
                    && (count = input.read(buffer, 0,
                    Math.min(buffer.length, MAX_STATUS_BYTES - output.size()))) >= 0) {
                output.write(buffer, 0, count);
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8).trim();
        }
    }

    static String readLiveReport(Context context) throws IOException {
        final BfuRuntime.Layout layout;
        try {
            layout = BfuRuntime.layout(context);
        } catch (IllegalStateException e) {
            throw new IOException(e.getMessage(), e);
        }
        if (!layout.namespaceProbeBinary.isFile()
                || !layout.namespaceProbeBinary.canExecute()) {
            return "DawnShell namespace launcher is not provisioned.";
        }
        try {
            BfuSu.Result result = BfuSu.runRaw(namespaceCommand(layout, "report"),
                    25_000L);
            String header = "exit=" + result.exitCode + " timeout=" + result.timedOut;
            if (result.output.isEmpty()) return header;
            return header + "\n\n" + result.output;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted while reading codec long-run journal", e);
        }
    }

    static void recordFailure(Context context, Operation operation, String reason) {
        String summary = operation.name() + " " + BfuSu.sanitize(reason);
        try {
            writeStatus(context, "FAILED " + summary);
        } catch (IOException ignored) {
            // The original failure remains the useful diagnostic.
        }
        HardwareCodecProbe.recordBrokerEvent(context,
                "LONG_RUN_CONTROL_FAILED " + summary);
    }

    private static String namespaceCommand(BfuRuntime.Layout layout, String operation) {
        return BfuSu.shellQuote(layout.namespaceProbeBinary.getAbsolutePath())
                + " codec-long-run " + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH)
                + " " + BfuSu.shellQuote(layout.run.getAbsolutePath())
                + " " + BfuSu.shellQuote(operation);
    }

    private static void writeStatus(Context context, String value) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File destination = new File(deContext.getFilesDir(), STATUS_FILE);
        File temporary = new File(deContext.getFilesDir(), STATUS_FILE + ".new");
        String contents = System.currentTimeMillis() + " " + value + "\n";
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(contents.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        setOwnerOnly(temporary);
        if (destination.exists() && !destination.delete()) {
            throw new IOException("cannot replace hardware codec long-run status");
        }
        if (!temporary.renameTo(destination)) {
            throw new IOException("cannot publish hardware codec long-run status");
        }
        setOwnerOnly(destination);
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setOwnerOnly(File file) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
    }
}
