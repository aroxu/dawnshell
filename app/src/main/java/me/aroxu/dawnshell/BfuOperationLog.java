package me.aroxu.dawnshell;

import android.content.Context;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/** Persistent, non-secret UI operation history stored in Device Protected Storage. */
final class BfuOperationLog {

    private static final String LOG_FILE = "bfu-operation.log";
    private static final int MAX_TAIL_BYTES = 48 * 1024;
    private static final Object FILE_LOCK = new Object();

    private BfuOperationLog() {}

    static void append(Context context, String message) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File file = new File(deContext.getFilesDir(), LOG_FILE);
        String clean = BfuSu.sanitize(message);
        if (clean == null || clean.isEmpty()) clean = "(empty operation result)";

        SimpleDateFormat dateFormat = new SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        dateFormat.setTimeZone(TimeZone.getTimeZone("UTC"));
        String line = "[" + dateFormat.format(new Date()) + "] "
                + clean.replace('\0', ' ') + "\n";

        synchronized (FILE_LOCK) {
            try (FileOutputStream output = new FileOutputStream(file, true)) {
                output.write(line.getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            setOwnerOnly(file);
        }
    }

    static String readTail(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        File file = new File(deContext.getFilesDir(), LOG_FILE);
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

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setOwnerOnly(File file) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
    }
}
