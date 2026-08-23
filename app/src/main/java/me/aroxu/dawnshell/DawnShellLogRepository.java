package me.aroxu.dawnshell;

import android.content.Context;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;

/** Read-only view over DawnShell's non-secret DE operation and probe logs. */
final class DawnShellLogRepository {

    static final String OPERATIONS = "operations";
    static final String INSTALLATION = "installation";
    static final String CONFIGURATION = "configuration";
    static final String COMPATIBILITY = "compatibility";
    static final String LIFECYCLE = "lifecycle";
    static final String DIAGNOSTICS = "diagnostics";

    private static final int BOOT_LOG_TAIL_BYTES = 32 * 1024;

    private DawnShellLogRepository() {}

    static boolean isKnown(String type) {
        return OPERATIONS.equals(type)
                || INSTALLATION.equals(type)
                || CONFIGURATION.equals(type)
                || COMPATIBILITY.equals(type)
                || LIFECYCLE.equals(type)
                || DIAGNOSTICS.equals(type);
    }

    static int titleRes(String type) {
        switch (type) {
            case OPERATIONS:
                return R.string.dawnshell_log_operations_title;
            case INSTALLATION:
                return R.string.dawnshell_log_installation_title;
            case CONFIGURATION:
                return R.string.dawnshell_log_configuration_title;
            case COMPATIBILITY:
                return R.string.dawnshell_log_compatibility_title;
            case LIFECYCLE:
                return R.string.dawnshell_log_lifecycle_title;
            case DIAGNOSTICS:
                return R.string.dawnshell_log_diagnostics_title;
            default:
                return R.string.dawnshell_log_unknown;
        }
    }

    static int descriptionRes(String type) {
        switch (type) {
            case OPERATIONS:
                return R.string.dawnshell_log_operations_description;
            case INSTALLATION:
                return R.string.dawnshell_log_installation_description;
            case CONFIGURATION:
                return R.string.dawnshell_log_configuration_description;
            case COMPATIBILITY:
                return R.string.dawnshell_log_compatibility_description;
            case LIFECYCLE:
                return R.string.dawnshell_log_lifecycle_description;
            case DIAGNOSTICS:
                return R.string.dawnshell_log_diagnostics_description;
            default:
                return R.string.dawnshell_log_unknown;
        }
    }

    static String read(Context context, String type) throws IOException {
        switch (type) {
            case OPERATIONS:
                return orEmptyMessage(context, BfuOperationLog.readTail(context));
            case INSTALLATION:
                return statusAndOutput(context, DebianRootfsInstaller.readStatus(context),
                        DebianRootfsInstaller.readLogTail(context));
            case CONFIGURATION:
                return statusAndOutput(context, DebianSystemProvisioner.readStatus(context),
                        DebianSystemProvisioner.readLogTail(context));
            case COMPATIBILITY:
                return statusAndOutput(context,
                        DockerNetworkProvisioner.readStatus(context),
                        DockerNetworkProvisioner.readLogTail(context));
            case LIFECYCLE:
                return statusAndOutput(context, DebianLauncher.readStatus(context),
                        DebianLauncher.readLogTail(context));
            case DIAGNOSTICS:
                return readDiagnostics(context);
            default:
                return context.getString(R.string.dawnshell_log_unknown);
        }
    }

    static String readSummary(Context context, String type) throws IOException {
        String value;
        switch (type) {
            case OPERATIONS:
                value = BfuOperationLog.readTail(context);
                break;
            case INSTALLATION:
                value = DebianRootfsInstaller.readStatus(context);
                break;
            case CONFIGURATION:
                value = DebianSystemProvisioner.readStatus(context);
                break;
            case COMPATIBILITY:
                value = DockerNetworkProvisioner.readStatus(context);
                break;
            case LIFECYCLE:
                value = DebianLauncher.readStatus(context);
                break;
            case DIAGNOSTICS:
                value = readProbeSafely(context,
                        () -> BfuDebianRuntimeProbe.readLastPersistentResult(context));
                if (value.isEmpty()) {
                    value = readProbeSafely(context,
                            () -> BfuRootfsProbe.readLastPersistentResult(context));
                }
                if (value.isEmpty()) {
                    value = readBootEvents(context);
                }
                break;
            default:
                value = "";
        }
        String last = lastNonEmptyLine(value);
        if (last.isEmpty()) return context.getString(R.string.dawnshell_log_summary_none);
        return truncate(last, 180);
    }

    private static String statusAndOutput(Context context, String status, String output) {
        return section(context, R.string.dawnshell_log_section_status,
                orEmptyMessage(context, status))
                + "\n\n"
                + section(context, R.string.dawnshell_log_section_output,
                orEmptyMessage(context, output));
    }

    private static String readDiagnostics(Context context) {
        StringBuilder result = new StringBuilder();
        result.append(context.getString(R.string.dawnshell_diagnostics_settings,
                Boolean.toString(BfuPreferences.isEnabled(context)),
                Boolean.toString(BfuPreferences.allowCeReadableBfu(context)),
                BfuPreferences.cgroupPolicy(context),
                BfuPreferences.dockerNetworkPolicy(context),
                Boolean.toString(BfuPreferences.dockerHostIpcCompatibility(context)),
                BfuPreferences.usbPassthroughMode(context),
                BfuPreferences.usbExclusiveDeviceIds(context)));
        appendSection(result, context, R.string.dawnshell_log_section_locked_boot,
                readProbeSafely(context, () -> readBootEvents(context)));
        appendSection(result, context, R.string.dawnshell_log_section_root_authorization,
                readProbeSafely(context,
                        () -> BfuRootAuthorization.readLastPersistentResult(context)));
        appendSection(result, context, R.string.dawnshell_log_section_root_probe,
                readProbeSafely(context,
                        () -> BfuRootProbe.readLastPersistentResult(context)));
        appendSection(result, context, R.string.dawnshell_log_section_ce_probe,
                readProbeSafely(context,
                        () -> BfuCeIsolationProbe.readLastPersistentResult(context)));
        appendSection(result, context, R.string.dawnshell_log_section_rootfs_probe,
                readProbeSafely(context,
                        () -> BfuRootfsProbe.readLastPersistentResult(context)));
        appendSection(result, context, R.string.dawnshell_log_section_runtime_probe,
                readProbeSafely(context,
                        () -> BfuDebianRuntimeProbe.readLastPersistentResult(context)));
        return result.toString();
    }

    private static void appendSection(StringBuilder result, Context context,
                                      int titleRes, String value) {
        result.append("\n\n").append(section(context, titleRes,
                orEmptyMessage(context, value)));
    }

    private static String section(Context context, int titleRes, String value) {
        return context.getString(R.string.dawnshell_log_section_format,
                context.getString(titleRes), value);
    }

    private static String readBootEvents(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        return readTail(new File(deContext.getFilesDir(), "bfu-boot.log"),
                BOOT_LOG_TAIL_BYTES);
    }

    private static String readTail(File file, int maximumBytes) throws IOException {
        if (!file.isFile()) return "";
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            long length = input.length();
            long start = Math.max(0L, length - maximumBytes);
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

    private static String readProbeSafely(Context context, LogReader reader) {
        try {
            return reader.read();
        } catch (IOException e) {
            return context.getString(R.string.dawnshell_log_read_failed,
                    BfuSu.sanitize(e.getMessage()));
        }
    }

    private static String orEmptyMessage(Context context, String value) {
        return value == null || value.trim().isEmpty()
                ? context.getString(R.string.dawnshell_log_empty) : value;
    }

    private static String lastNonEmptyLine(String value) {
        if (value == null || value.isEmpty()) return "";
        String[] lines = value.split("\\r?\\n");
        for (int i = lines.length - 1; i >= 0; i--) {
            String line = lines[i].trim();
            if (!line.isEmpty()) return line;
        }
        return "";
    }

    private static String truncate(String value, int maximum) {
        if (value.length() <= maximum) return value;
        return value.substring(0, Math.max(0, maximum - 1)) + "…";
    }

    private interface LogReader {
        String read() throws IOException;
    }
}
