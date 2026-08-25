package me.aroxu.dawnshell;

import android.content.Context;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import android.os.UserManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/**
 * Enumerates Android video codecs and proves that explicitly classified hardware
 * AVC instances can be created. Results contain no media payload or credentials
 * and are persisted exclusively in Device Protected Storage.
 */
final class HardwareCodecProbe {

    static final String MIME_AVC = "video/avc";
    static final String MIME_HEVC = "video/hevc";

    private static final String TAG = "DawnShellCodec";
    private static final String DIRECTORY = "hardware-codec";
    private static final String STATUS_FILE = "probe.status";
    private static final String LOG_FILE = "probe.log";
    private static final String CAPABILITIES_FILE = "capabilities.json";
    private static final int MAX_LOG_BYTES = 128 * 1024;
    private static final int ROTATE_LOG_BYTES = 512 * 1024;
    private static final Object FILE_LOCK = new Object();

    private HardwareCodecProbe() {}

    static Result run(Context context, String trigger) {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        boolean unlocked = isUserUnlocked(context);
        long started = System.currentTimeMillis();
        append(deContext, "============================================================");
        append(deContext, "STAGE: Android MediaCodec probe trigger=" + clean(trigger)
                + " user_unlocked=" + unlocked + " sdk=" + Build.VERSION.SDK_INT);
        writeStatus(deContext, "RUNNING trigger=" + clean(trigger)
                + " user_unlocked=" + unlocked);

        JSONArray codecs = new JSONArray();
        List<Candidate> avcDecoders = new ArrayList<>();
        List<Candidate> avcEncoders = new ArrayList<>();
        List<Candidate> hevcDecoders = new ArrayList<>();
        List<Candidate> hevcEncoders = new ArrayList<>();
        int videoCodecCount = 0;
        try {
            MediaCodecInfo[] infos = new MediaCodecList(
                    MediaCodecList.ALL_CODECS).getCodecInfos();
            for (MediaCodecInfo info : infos) {
                String name = info.getName();
                if (isSecureCodec(name)) continue;
                Classification classification = classify(info);
                JSONArray types = new JSONArray();
                boolean video = false;
                for (String type : info.getSupportedTypes()) {
                    if (!type.toLowerCase(Locale.US).startsWith("video/")) continue;
                    video = true;
                    JSONObject typeResult = describeType(info, type);
                    types.put(typeResult);
                    if (classification.usableAsHardware()) {
                        Candidate candidate = new Candidate(name, type,
                                info.isEncoder(), classification);
                        if (MIME_AVC.equalsIgnoreCase(type)) {
                            (info.isEncoder() ? avcEncoders : avcDecoders).add(candidate);
                        } else if (MIME_HEVC.equalsIgnoreCase(type)) {
                            (info.isEncoder() ? hevcEncoders : hevcDecoders).add(candidate);
                        }
                    }
                }
                if (!video) continue;
                videoCodecCount++;
                JSONObject item = new JSONObject();
                item.put("name", name);
                if (Build.VERSION.SDK_INT >= 29) {
                    item.put("canonical_name", info.getCanonicalName());
                    item.put("alias", info.isAlias());
                }
                item.put("encoder", info.isEncoder());
                item.put("hardware", classification.hardware);
                item.put("software_only", classification.software);
                item.put("vendor", classification.vendor);
                item.put("classification", classification.source);
                item.put("types", types);
                codecs.put(item);
                append(deContext, "CODEC name=" + name + " encoder="
                        + info.isEncoder() + " hardware=" + classification.hardware
                        + " vendor=" + classification.vendor + " classification="
                        + classification.source + " types=" + typesToText(types));
            }

            Attempt avcDecoder = createFirst(deContext, avcDecoders, "avc_decoder");
            Attempt avcEncoder = createFirst(deContext, avcEncoders, "avc_encoder");
            Attempt hevcDecoder = createFirst(deContext, hevcDecoders, "hevc_decoder");
            Attempt hevcEncoder = createFirst(deContext, hevcEncoders, "hevc_encoder");

            JSONObject root = new JSONObject();
            root.put("schema", 1);
            root.put("generated_at_unix_ms", System.currentTimeMillis());
            root.put("android_sdk", Build.VERSION.SDK_INT);
            root.put("android_release", Build.VERSION.RELEASE);
            root.put("android_abis", new JSONArray(Arrays.asList(
                    Build.SUPPORTED_ABIS)));
            root.put("user_unlocked", unlocked);
            root.put("classification_note", Build.VERSION.SDK_INT >= 29
                    ? "Android MediaCodecInfo hardware/vendor flags"
                    : "conservative codec-name heuristic; never treated as definitive");
            root.put("video_codecs", codecs);
            root.put("avc_decoder", avcDecoder.toJson());
            root.put("avc_encoder", avcEncoder.toJson());
            root.put("hevc_decoder", hevcDecoder.toJson());
            root.put("hevc_encoder", hevcEncoder.toJson());
            writeAtomic(file(deContext, CAPABILITIES_FILE),
                    root.toString(2) + "\n");

            boolean passed = avcDecoder.created || avcEncoder.created;
            String summary = (passed ? "SUCCEEDED" : "UNAVAILABLE")
                    + " user_unlocked=" + unlocked
                    + " video_codecs=" + videoCodecCount
                    + " avc_decoder=" + avcDecoder.summary()
                    + " avc_encoder=" + avcEncoder.summary()
                    + " hevc_decoder=" + hevcDecoder.summary()
                    + " hevc_encoder=" + hevcEncoder.summary()
                    + " classification=" + (Build.VERSION.SDK_INT >= 29
                    ? "platform" : "heuristic")
                    + " elapsed_ms=" + (System.currentTimeMillis() - started);
            writeStatus(deContext, summary);
            append(deContext, "RESULT: " + summary);
            return new Result(passed, summary);
        } catch (RuntimeException | JSONException | IOException e) {
            String summary = "FAILED user_unlocked=" + unlocked + " error="
                    + clean(e.getClass().getSimpleName() + ": " + e.getMessage())
                    + " elapsed_ms=" + (System.currentTimeMillis() - started);
            writeStatus(deContext, summary);
            append(deContext, "ERROR: " + summary);
            Log.e(TAG, "MediaCodec probe failed", e);
            return new Result(false, summary);
        }
    }

    static String readStatus(Context context) throws IOException {
        return readSmallFile(file(BfuPreferences.deviceProtectedContext(context),
                STATUS_FILE), 16 * 1024);
    }

    static String readCapabilities(Context context) throws IOException {
        return readSmallFile(file(BfuPreferences.deviceProtectedContext(context),
                CAPABILITIES_FILE), 512 * 1024);
    }

    static String readLogTail(Context context) throws IOException {
        File log = file(BfuPreferences.deviceProtectedContext(context), LOG_FILE);
        if (!log.isFile()) return "";
        synchronized (FILE_LOCK) {
            try (RandomAccessFile input = new RandomAccessFile(log, "r")) {
                long length = input.length();
                long start = Math.max(0L, length - MAX_LOG_BYTES);
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

    static CodecSelection selectHardwareCodec(String mime, boolean encoder) {
        List<CodecSelection> selections = selectHardwareCodecs(mime, encoder);
        return selections.isEmpty() ? null : selections.get(0);
    }

    static List<CodecSelection> selectHardwareCodecs(String mime, boolean encoder) {
        List<CodecSelection> selections = new ArrayList<>();
        MediaCodecInfo[] infos = new MediaCodecList(
                MediaCodecList.ALL_CODECS).getCodecInfos();
        for (MediaCodecInfo info : infos) {
            if (info.isEncoder() != encoder || isSecureCodec(info.getName())) continue;
            Classification classification = classify(info);
            if (!classification.usableAsHardware()) continue;
            for (String type : info.getSupportedTypes()) {
                if (mime.equalsIgnoreCase(type)) {
                    int[] colorFormats = new int[0];
                    try {
                        colorFormats = info.getCapabilitiesForType(type)
                                .colorFormats.clone();
                    } catch (RuntimeException ignored) {
                        // Session configuration will still try this codec.
                    }
                    selections.add(new CodecSelection(info.getName(),
                            classification.source, colorFormats));
                    break;
                }
            }
        }
        return selections;
    }

    static void recordRuntimeEvent(Context context, String value) {
        append(BfuPreferences.deviceProtectedContext(context), "RUNTIME " + value);
    }

    private static JSONObject describeType(MediaCodecInfo info, String type) {
        JSONObject result = new JSONObject();
        try {
            result.put("mime", type.toLowerCase(Locale.US));
            MediaCodecInfo.CodecCapabilities capabilities =
                    info.getCapabilitiesForType(type);
            result.put("color_formats", new JSONArray(toList(
                    capabilities.colorFormats)));
            JSONArray profiles = new JSONArray();
            for (MediaCodecInfo.CodecProfileLevel level : capabilities.profileLevels) {
                JSONObject item = new JSONObject();
                item.put("profile", level.profile);
                item.put("level", level.level);
                profiles.put(item);
            }
            result.put("profile_levels", profiles);
            if (capabilities.getVideoCapabilities() != null) {
                MediaCodecInfo.VideoCapabilities video =
                        capabilities.getVideoCapabilities();
                result.put("width", video.getSupportedWidths().toString());
                result.put("height", video.getSupportedHeights().toString());
                result.put("frame_rate", video.getSupportedFrameRates().toString());
                result.put("bitrate", video.getBitrateRange().toString());
            }
        } catch (RuntimeException | JSONException e) {
            try {
                result.put("capability_error", clean(e.getMessage()));
            } catch (JSONException ignored) {
                // The object and key are constants and should never fail here.
            }
        }
        return result;
    }

    private static Attempt createFirst(Context context, List<Candidate> candidates,
                                       String role) {
        if (candidates.isEmpty()) {
            append(context, "INSTANCE role=" + role + " result=no_hardware_candidate");
            return Attempt.unavailable("no_hardware_candidate");
        }
        String lastError = "unknown";
        for (Candidate candidate : candidates) {
            MediaCodec codec = null;
            long started = System.currentTimeMillis();
            try {
                codec = MediaCodec.createByCodecName(candidate.name);
                String canonical = Build.VERSION.SDK_INT >= 29
                        ? codec.getCanonicalName() : candidate.name;
                append(context, "INSTANCE role=" + role + " result=created name="
                        + candidate.name + " canonical=" + canonical
                        + " classification=" + candidate.classification.source
                        + " elapsed_ms=" + (System.currentTimeMillis() - started));
                return Attempt.created(candidate.name, canonical,
                        candidate.classification.source);
            } catch (IOException | RuntimeException e) {
                lastError = clean(e.getClass().getSimpleName() + ": " + e.getMessage());
                append(context, "INSTANCE role=" + role + " result=failed name="
                        + candidate.name + " error=" + lastError
                        + " elapsed_ms=" + (System.currentTimeMillis() - started));
            } finally {
                if (codec != null) {
                    try {
                        codec.release();
                    } catch (RuntimeException e) {
                        append(context, "INSTANCE role=" + role
                                + " release_warning=" + clean(e.getMessage()));
                    }
                }
            }
        }
        return Attempt.unavailable(lastError);
    }

    private static Classification classify(MediaCodecInfo info) {
        if (Build.VERSION.SDK_INT >= 29) {
            return new Classification(info.isHardwareAccelerated(),
                    info.isSoftwareOnly(), info.isVendor(), "platform_api29");
        }
        String name = info.getName().toLowerCase(Locale.US);
        if (isConservativeSoftwareCodecName(name)) {
            return new Classification(false, true, false,
                    "heuristic_software_api" + Build.VERSION.SDK_INT);
        }
        if (isConservativeHardwareCodecName(name)) {
            return new Classification(true, false, true,
                    "heuristic_vendor_api" + Build.VERSION.SDK_INT);
        }
        return new Classification(false, false, false,
                "unknown_api" + Build.VERSION.SDK_INT);
    }

    private static boolean startsWithAny(String value, String... prefixes) {
        for (String prefix : prefixes) if (value.startsWith(prefix)) return true;
        return false;
    }

    static boolean isConservativeSoftwareCodecName(String codecName) {
        String name = codecName.toLowerCase(Locale.US);
        return startsWithAny(name, "omx.google.", "c2.android.", "omx.ffmpeg.",
                "omx.pv.", "omx.k3.ffmpeg.");
    }

    static boolean isConservativeHardwareCodecName(String codecName) {
        String name = codecName.toLowerCase(Locale.US);
        return startsWithAny(name, "omx.exynos.", "omx.sec.", "c2.exynos.",
                "omx.qcom.", "c2.qti.", "omx.mtk.", "c2.mtk.",
                "omx.intel.", "omx.nvidia.", "omx.rk.", "omx.amlogic.",
                "omx.allwinner.");
    }

    private static boolean isSecureCodec(String name) {
        String lower = name.toLowerCase(Locale.US);
        return lower.endsWith(".secure") || lower.contains("secure.decoder")
                || lower.contains("secure.encoder");
    }

    private static boolean isUserUnlocked(Context context) {
        UserManager manager = (UserManager) context.getSystemService(
                Context.USER_SERVICE);
        return manager != null && manager.isUserUnlocked();
    }

    private static String typesToText(JSONArray types) {
        List<String> values = new ArrayList<>();
        for (int index = 0; index < types.length(); index++) {
            JSONObject item = types.optJSONObject(index);
            if (item != null) values.add(item.optString("mime"));
        }
        return Arrays.toString(values.toArray(new String[0]));
    }

    private static List<Integer> toList(int[] values) {
        List<Integer> result = new ArrayList<>(values.length);
        for (int value : values) result.add(value);
        return result;
    }

    private static File directory(Context context) {
        File directory = new File(context.getFilesDir(), DIRECTORY);
        if (!directory.isDirectory() && !directory.mkdirs()
                && !directory.isDirectory()) {
            throw new IllegalStateException("Could not create hardware codec DE directory");
        }
        setOwnerOnly(directory);
        return directory;
    }

    private static File file(Context context, String name) {
        return new File(directory(context), name);
    }

    private static void writeStatus(Context context, String value) {
        try {
            writeAtomic(file(context, STATUS_FILE), clean(value) + "\n");
        } catch (IOException | RuntimeException e) {
            Log.e(TAG, "Could not persist MediaCodec status", e);
        }
    }

    private static void writeAtomic(File destination, String value) throws IOException {
        File temporary = new File(destination.getParentFile(),
                destination.getName() + ".tmp");
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        setOwnerOnly(temporary);
        if (!temporary.renameTo(destination)) {
            throw new IOException("Could not publish " + destination.getName());
        }
        setOwnerOnly(destination);
    }

    private static String readSmallFile(File file, int maximum) throws IOException {
        if (!file.isFile()) return "";
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while (output.size() < maximum && (count = input.read(buffer, 0,
                    Math.min(buffer.length, maximum - output.size()))) >= 0) {
                output.write(buffer, 0, count);
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8).trim();
        }
    }

    private static void append(Context context, String value) {
        try {
            File log = file(context, LOG_FILE);
            String line = "[" + utcTimestamp() + "] " + clean(value) + "\n";
            synchronized (FILE_LOCK) {
                rotateLogIfNeeded(log);
                boolean created = !log.isFile();
                try (FileOutputStream output = new FileOutputStream(log, true)) {
                    output.write(line.getBytes(StandardCharsets.UTF_8));
                    output.getFD().sync();
                }
                // Diagnostics may run in the isolated :codec process, so
                // FILE_LOCK does not serialise it against the main app.
                // Re-applying the mode on every append raced with the other
                // process and could leave the file inaccessible.
                if (created || !log.canRead() || !log.canWrite()) setOwnerOnly(log);
            }
            Log.i(TAG, clean(value));
        } catch (IOException | RuntimeException e) {
            Log.e(TAG, "Could not append MediaCodec log", e);
        }
    }

    private static void rotateLogIfNeeded(File log) throws IOException {
        if (!log.isFile() || log.length() <= ROTATE_LOG_BYTES) return;
        byte[] tail;
        try (RandomAccessFile input = new RandomAccessFile(log, "r")) {
            long start = Math.max(0L, input.length() - MAX_LOG_BYTES);
            input.seek(start);
            tail = new byte[(int) (input.length() - start)];
            input.readFully(tail);
        }
        int offset = 0;
        while (offset < tail.length && tail[offset] != '\n') offset++;
        if (offset < tail.length) offset++;
        try (FileOutputStream output = new FileOutputStream(log, false)) {
            output.write("[log rotated; older codec probes omitted]\n".getBytes(
                    StandardCharsets.UTF_8));
            output.write(tail, offset, tail.length - offset);
            output.getFD().sync();
        }
    }

    private static String utcTimestamp() {
        SimpleDateFormat format = new SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }

    private static String clean(String value) {
        String clean = BfuSu.sanitize(value);
        if (clean == null || clean.trim().isEmpty()) return "unknown";
        return clean.replace('\n', ' ').replace('\r', ' ').replace('\0', ' ');
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setOwnerOnly(File file) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        if (file.isDirectory()) file.setExecutable(true, true);
        file.setWritable(true, true);
    }

    static final class Result {
        final boolean passed;
        final String summary;

        Result(boolean passed, String summary) {
            this.passed = passed;
            this.summary = summary;
        }
    }

    static final class CodecSelection {
        final String name;
        final String classification;
        final int[] colorFormats;

        CodecSelection(String name, String classification, int[] colorFormats) {
            this.name = name;
            this.classification = classification;
            this.colorFormats = colorFormats;
        }
    }

    private static final class Candidate {
        final String name;
        final String mime;
        final boolean encoder;
        final Classification classification;

        Candidate(String name, String mime, boolean encoder,
                  Classification classification) {
            this.name = name;
            this.mime = mime;
            this.encoder = encoder;
            this.classification = classification;
        }
    }

    private static final class Classification {
        final boolean hardware;
        final boolean software;
        final boolean vendor;
        final String source;

        Classification(boolean hardware, boolean software, boolean vendor,
                       String source) {
            this.hardware = hardware;
            this.software = software;
            this.vendor = vendor;
            this.source = source;
        }

        boolean usableAsHardware() {
            return hardware && !software;
        }
    }

    private static final class Attempt {
        final boolean created;
        final String name;
        final String canonical;
        final String classification;
        final String error;

        private Attempt(boolean created, String name, String canonical,
                        String classification, String error) {
            this.created = created;
            this.name = name;
            this.canonical = canonical;
            this.classification = classification;
            this.error = error;
        }

        static Attempt created(String name, String canonical,
                               String classification) {
            return new Attempt(true, name, canonical, classification, "");
        }

        static Attempt unavailable(String error) {
            return new Attempt(false, "", "", "", clean(error));
        }

        String summary() {
            if (!created) return "unavailable(" + error + ")";
            return "created(" + canonical + "," + classification + ")";
        }

        JSONObject toJson() throws JSONException {
            JSONObject result = new JSONObject();
            result.put("created", created);
            if (created) {
                result.put("name", name);
                result.put("canonical_name", canonical);
                result.put("classification", classification);
            } else {
                result.put("error", error);
            }
            return result;
        }
    }
}
