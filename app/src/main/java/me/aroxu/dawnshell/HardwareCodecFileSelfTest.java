package me.aroxu.dawnshell;

import android.content.Context;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.SystemClock;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;

/**
 * File-backed hardware AVC decoder test.
 *
 * <p>The compressed media is downloaded into Device Protected Storage and is
 * consumed directly by MediaExtractor/MediaCodec. No media payload crosses the
 * local control socket. The socket bridge remains available for interactive
 * FFmpeg integration, but its packet framing cannot affect this test.
 */
final class HardwareCodecFileSelfTest {

    static final String TEST_URL =
            "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/"
                    + "Big_Buck_Bunny_1080_10s_5MB.mp4";

    private static final String DIRECTORY = "hardware-codec/file-self-test";
    private static final String INPUT_FILE = "Big_Buck_Bunny_1080_10s_5MB.mp4";
    private static final String STATUS_FILE = "status.txt";
    private static final String REPORT_FILE = "report.json";
    private static final long MAX_INPUT_BYTES = 8L * 1024L * 1024L;
    private static final long DECODE_TIMEOUT_MS = 60_000L;

    private HardwareCodecFileSelfTest() {}

    static Result run(Context context, long token) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        long started = SystemClock.elapsedRealtime();
        writeStatus(deContext, "RUNNING token=" + token + " stage=validate_input");
        HardwareCodecProbe.recordBrokerEvent(deContext,
                "FILE_SELF_TEST_STARTED token=" + token + " source=" + TEST_URL
                        + " transport=file");
        try {
            File directory = directory(deContext);
            File input = inputFile(deContext);
            if (!input.isFile() || input.length() < 1024 * 1024L
                    || input.length() > MAX_INPUT_BYTES) {
                throw new IOException("Debian-downloaded test video is missing or invalid");
            }
            writeStatus(deContext, "RUNNING token=" + token + " stage=decode"
                    + " source=debian_wget bytes=" + input.length());
            DecodeResult decode = decodeAvc(input);
            String sha256 = sha256(input);

            JSONObject report = new JSONObject();
            report.put("schema", 1);
            report.put("token", token);
            report.put("source_url", TEST_URL);
            report.put("input_file", input.getAbsolutePath());
            report.put("input_bytes", input.length());
            report.put("input_sha256", sha256);
            report.put("downloaded_by", "debian_wget");
            report.put("transport", "device_protected_file");
            report.put("media_socket_bytes", 0);
            report.put("mime", decode.mime);
            report.put("width", decode.width);
            report.put("height", decode.height);
            report.put("codec_name", decode.codecName);
            report.put("classification", decode.classification);
            report.put("queued_samples", decode.queuedSamples);
            report.put("decoded_frames", decode.decodedFrames);
            report.put("saw_output_format", decode.sawOutputFormat);
            report.put("saw_eos", decode.sawEos);
            report.put("first_pts_us", decode.firstPtsUs);
            report.put("last_pts_us", decode.lastPtsUs);
            report.put("elapsed_ms", SystemClock.elapsedRealtime() - started);
            writeAtomic(new File(directory, REPORT_FILE), report.toString(2) + "\n");

            String summary = "PASSED token=" + token
                    + " codec=" + clean(decode.codecName)
                    + " classification=" + clean(decode.classification)
                    + " size=" + decode.width + "x" + decode.height
                    + " samples=" + decode.queuedSamples
                    + " frames=" + decode.decodedFrames
                    + " eos=" + decode.sawEos
                    + " transport=device_protected_file socket_media_bytes=0"
                    + " elapsed_ms=" + (SystemClock.elapsedRealtime() - started);
            writeStatus(deContext, summary);
            HardwareCodecProbe.recordBrokerEvent(deContext,
                    "FILE_SELF_TEST_" + summary);
            return new Result(true, summary);
        } catch (Exception e) {
            String summary = "FAILED token=" + token + " error="
                    + clean(e.getClass().getSimpleName() + ": " + e.getMessage())
                    + " transport=device_protected_file socket_media_bytes=0"
                    + " elapsed_ms=" + (SystemClock.elapsedRealtime() - started);
            writeStatus(deContext, summary);
            HardwareCodecProbe.recordBrokerEvent(deContext,
                    "FILE_SELF_TEST_" + summary);
            return new Result(false, summary);
        }
    }

    static String readStatus(Context context) throws IOException {
        File file = new File(directory(BfuPreferences.deviceProtectedContext(context)),
                STATUS_FILE);
        if (!file.isFile()) return "";
        byte[] data = new byte[(int) Math.min(file.length(), 16 * 1024L)];
        try (FileInputStream input = new FileInputStream(file)) {
            int offset = 0;
            while (offset < data.length) {
                int count = input.read(data, offset, data.length - offset);
                if (count < 0) break;
                offset += count;
            }
            return new String(data, 0, offset, StandardCharsets.UTF_8).trim();
        }
    }

    static File inputFile(Context context) throws IOException {
        return new File(directory(BfuPreferences.deviceProtectedContext(context)), INPUT_FILE);
    }

    private static DecodeResult decodeAvc(File input) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec codec = null;
        try {
            extractor.setDataSource(input.getAbsolutePath());
            int track = -1;
            MediaFormat format = null;
            for (int index = 0; index < extractor.getTrackCount(); index++) {
                MediaFormat candidate = extractor.getTrackFormat(index);
                String mime = candidate.getString(MediaFormat.KEY_MIME);
                if (HardwareCodecProbe.MIME_AVC.equalsIgnoreCase(mime)) {
                    track = index;
                    format = candidate;
                    break;
                }
            }
            if (track < 0 || format == null) {
                throw new IOException("downloaded MP4 has no AVC video track");
            }
            int width = format.getInteger(MediaFormat.KEY_WIDTH);
            int height = format.getInteger(MediaFormat.KEY_HEIGHT);
            if (width != 1920 || height != 1080) {
                throw new IOException("unexpected test dimensions " + width + "x" + height);
            }
            java.util.List<HardwareCodecProbe.CodecSelection> selections =
                    HardwareCodecProbe.selectHardwareCodecs(
                            HardwareCodecProbe.MIME_AVC, false);
            if (selections.isEmpty()) {
                throw new IOException("no conservatively classified hardware AVC decoder");
            }
            Exception last = null;
            HardwareCodecProbe.CodecSelection selected = null;
            for (HardwareCodecProbe.CodecSelection candidate : selections) {
                try {
                    codec = MediaCodec.createByCodecName(candidate.name);
                    codec.configure(format, null, null, 0);
                    codec.start();
                    selected = candidate;
                    break;
                } catch (Exception e) {
                    last = e;
                    if (codec != null) {
                        try { codec.release(); } catch (RuntimeException ignored) {}
                        codec = null;
                    }
                }
            }
            if (codec == null || selected == null) {
                throw new IOException("hardware AVC decoder configuration failed", last);
            }

            extractor.selectTrack(track);
            boolean inputEos = false;
            boolean outputEos = false;
            boolean sawFormat = false;
            int queued = 0;
            int frames = 0;
            long firstPts = -1L;
            long lastPts = -1L;
            long deadline = SystemClock.elapsedRealtime() + DECODE_TIMEOUT_MS;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (!outputEos && SystemClock.elapsedRealtime() < deadline) {
                if (!inputEos) {
                    int index = codec.dequeueInputBuffer(10_000L);
                    if (index >= 0) {
                        ByteBuffer buffer = codec.getInputBuffer(index);
                        if (buffer == null) throw new IOException("decoder input buffer is null");
                        buffer.clear();
                        int size = extractor.readSampleData(buffer, 0);
                        if (size < 0) {
                            codec.queueInputBuffer(index, 0, 0,
                                    Math.max(0L, extractor.getSampleTime()),
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputEos = true;
                        } else {
                            long pts = extractor.getSampleTime();
                            codec.queueInputBuffer(index, 0, size, pts, 0);
                            queued++;
                            extractor.advance();
                        }
                    }
                }
                int output = codec.dequeueOutputBuffer(info, 10_000L);
                if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    sawFormat = true;
                } else if (output >= 0) {
                    if (info.size > 0) {
                        if (firstPts < 0L) firstPts = info.presentationTimeUs;
                        if (lastPts > info.presentationTimeUs) {
                            codec.releaseOutputBuffer(output, false);
                            throw new IOException("decoder output timestamps are not monotonic");
                        }
                        lastPts = info.presentationTimeUs;
                        frames++;
                    }
                    outputEos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    codec.releaseOutputBuffer(output, false);
                }
            }
            if (!outputEos) throw new IOException("hardware AVC decode timed out before EOS");
            if (!sawFormat || queued < 100 || frames < queued - 4) {
                throw new IOException("incomplete hardware AVC decode: format=" + sawFormat
                        + " samples=" + queued + " frames=" + frames);
            }
            return new DecodeResult(HardwareCodecProbe.MIME_AVC, width, height,
                    selected.name, selected.classification, queued, frames,
                    sawFormat, true, firstPts, lastPts);
        } finally {
            if (codec != null) {
                try { codec.stop(); } catch (RuntimeException ignored) {}
                try { codec.release(); } catch (RuntimeException ignored) {}
            }
            extractor.release();
        }
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) digest.update(buffer, 0, count);
        }
        StringBuilder value = new StringBuilder(64);
        for (byte item : digest.digest()) value.append(String.format(Locale.US, "%02x", item));
        return value.toString();
    }

    private static File directory(Context context) throws IOException {
        File directory = new File(context.getFilesDir(), DIRECTORY);
        if (!directory.isDirectory() && !directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("could not create file self-test directory");
        }
        ownerOnly(directory);
        return directory;
    }

    private static void writeStatus(Context context, String value) {
        try {
            writeAtomic(new File(directory(context), STATUS_FILE), value + "\n");
        } catch (IOException e) {
            HardwareCodecProbe.recordBrokerEvent(context,
                    "FILE_SELF_TEST_STATUS_WRITE_FAILED error=" + clean(e.getMessage()));
        }
    }

    private static void writeAtomic(File destination, String value) throws IOException {
        File temporary = new File(destination.getParentFile(), destination.getName() + ".new");
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        ownerOnly(temporary);
        if (destination.exists() && !destination.delete()) {
            throw new IOException("could not replace " + destination.getName());
        }
        if (!temporary.renameTo(destination)) {
            throw new IOException("could not publish " + destination.getName());
        }
        ownerOnly(destination);
    }

    private static String clean(String value) {
        String clean = BfuSu.sanitize(value);
        return clean == null ? "unknown" : clean.replace('\n', ' ').replace('\r', ' ');
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void ownerOnly(File file) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
        if (file.isDirectory()) file.setExecutable(true, true);
    }

    static final class Result {
        final boolean passed;
        final String summary;

        Result(boolean passed, String summary) {
            this.passed = passed;
            this.summary = summary;
        }
    }

    private static final class DecodeResult {
        final String mime;
        final int width;
        final int height;
        final String codecName;
        final String classification;
        final int queuedSamples;
        final int decodedFrames;
        final boolean sawOutputFormat;
        final boolean sawEos;
        final long firstPtsUs;
        final long lastPtsUs;

        DecodeResult(String mime, int width, int height, String codecName,
                     String classification, int queuedSamples, int decodedFrames,
                     boolean sawOutputFormat, boolean sawEos, long firstPtsUs,
                     long lastPtsUs) {
            this.mime = mime;
            this.width = width;
            this.height = height;
            this.codecName = codecName;
            this.classification = classification;
            this.queuedSamples = queuedSamples;
            this.decodedFrames = decodedFrames;
            this.sawOutputFormat = sawOutputFormat;
            this.sawEos = sawEos;
            this.firstPtsUs = firstPtsUs;
            this.lastPtsUs = lastPtsUs;
        }
    }
}
