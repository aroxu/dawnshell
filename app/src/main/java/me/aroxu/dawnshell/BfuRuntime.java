package me.aroxu.dawnshell;

import android.content.Context;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Map;

final class BfuRuntime {

    private static final String TEST_SCRIPT =
            "#!/system/bin/sh\n" +
            "echo 'DawnShell DE executable OK'\n" +
            "echo \"uid=$(id -u)\"\n" +
            "echo \"cwd=$(pwd)\"\n";

    static final class Layout {
        final File root;
        final BfuArchitecture architecture;
        final File bin;
        final File etc;
        final File home;
        final File run;
        final File scripts;
        final File tmp;
        final File downloads;
        final File authorizedKeys;
        final File testScript;
        final File rootfsProbeScript;
        final File namespaceProbeBinary;
        final File toolboxBinary;
        final File gpgvBinary;
        final File pkgdetailsBinary;
        final File codecClientBinary;
        final File rootfsInstallerScript;
        final File systemdConfiguratorScript;
        final File dockerNetworkConfiguratorScript;
        final File hostUsbConfiguratorScript;
        final File codecFfmpegAdapterScript;
        final File lifecycleLog;
        final File debootstrapArchive;
        final File archiveKeyringPackage;
        final File sourceLock;
        final File runtimeProperties;
        final File codecTestVector;
        final File codecTestMetadata;
        final File codec720pTestVector;
        final File codec720pTestMetadata;
        final File codec1080pTestVector;
        final File codec1080pTestMetadata;

        Layout(File root, BfuArchitecture architecture) {
            this.root = root;
            this.architecture = architecture;
            bin = new File(root, "bin");
            etc = new File(root, "etc");
            home = new File(root, "home");
            run = new File(root, "run");
            scripts = new File(root, "scripts");
            tmp = new File(root, "tmp");
            downloads = new File(root, "downloads");
            authorizedKeys = new File(etc, "authorized_keys");
            testScript = new File(scripts, "test.sh");
            rootfsProbeScript = new File(scripts, "probe-rootfs.sh");
            namespaceProbeBinary = new File(bin, "bfu-namespace-probe");
            // BusyBox dispatches subcommands only when argv[0] begins with
            // "busybox". Keep the APK artifact descriptive but provision it
            // with the canonical runtime basename.
            toolboxBinary = new File(bin, "busybox");
            gpgvBinary = new File(bin, "gpgv");
            pkgdetailsBinary = new File(bin, "pkgdetails");
            codecClientBinary = new File(bin, "dawnshell-codec");
            rootfsInstallerScript = new File(scripts, "install-debian-rootfs.sh");
            systemdConfiguratorScript = new File(scripts,
                    "configure-debian-systemd.sh");
            dockerNetworkConfiguratorScript = new File(scripts,
                    "configure-docker-network.sh");
            hostUsbConfiguratorScript = new File(scripts,
                    "configure-host-usb.sh");
            codecFfmpegAdapterScript = new File(scripts,
                    "dawnshell-codec-ffmpeg.py");
            lifecycleLog = new File(run, "debian-lifecycle.log");
            debootstrapArchive = new File(downloads, "debootstrap_1.0.141.tar.gz");
            archiveKeyringPackage = new File(downloads,
                    "debian-archive-keyring_2025.1_all.deb");
            sourceLock = new File(downloads, "SOURCES.lock");
            runtimeProperties = new File(etc, "bootstrap-runtime.properties");
            codecTestVector = new File(downloads,
                    "avc-baseline-128x96-10fps.h264");
            codecTestMetadata = new File(downloads,
                    "avc-baseline-128x96-10fps.properties");
            codec720pTestVector = new File(downloads,
                    "avc-baseline-1280x720-30fps-30f.h264");
            codec720pTestMetadata = new File(downloads,
                    "avc-baseline-1280x720-30fps-30f.properties");
            codec1080pTestVector = new File(downloads,
                    "avc-high-1920x1080-30fps-60f.h264");
            codec1080pTestMetadata = new File(downloads,
                    "avc-high-1920x1080-30fps-60f.properties");
        }
    }

    private BfuRuntime() {}

    static Layout layout(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        return new Layout(new File(deContext.getFilesDir(), "bfu"),
                BfuArchitecture.detect());
    }

    static Layout provision(Context context) throws IOException {
        Context deContext = BfuPreferences.deviceProtectedContext(context);
        Layout layout = layout(deContext);
        ensureDirectory(layout.root);
        ensureDirectory(layout.bin);
        ensureDirectory(layout.etc);
        ensureDirectory(layout.home);
        ensureDirectory(layout.run);
        ensureDirectory(layout.scripts);
        ensureDirectory(layout.tmp);
        ensureDirectory(layout.downloads);

        writePrivateFile(layout.testScript, TEST_SCRIPT, true);
        copyPrivateAsset(deContext, "bfu/probe-rootfs.sh", layout.rootfsProbeScript, true);
        String abiAssets = layout.architecture.assetDirectory();
        copyPrivateAsset(deContext, abiAssets + "/bfu-namespace-probe",
                layout.namespaceProbeBinary, true);
        copyPrivateAsset(deContext, abiAssets + "/dawnshell-toolbox",
                layout.toolboxBinary, true);
        copyPrivateAsset(deContext, abiAssets + "/gpgv",
                layout.gpgvBinary, true);
        copyPrivateAsset(deContext, abiAssets + "/pkgdetails",
                layout.pkgdetailsBinary, true);
        copyPrivateAsset(deContext, abiAssets + "/dawnshell-codec",
                layout.codecClientBinary, true);
        copyPrivateAsset(deContext, abiAssets + "/runtime.properties",
                layout.runtimeProperties, false);
        verifyRuntimeProperties(layout.runtimeProperties, layout.architecture);
        // AAPT treats a .gz asset specially and strips the suffix. Keep the
        // APK entry as .tgz, then provision the verified bytes under the
        // conventional .tar.gz runtime filename.
        copyPrivateAsset(deContext, "bfu/bootstrap/debootstrap_1.0.141.tgz",
                layout.debootstrapArchive, false);
        copyPrivateAsset(deContext,
                "bfu/bootstrap/debian-archive-keyring_2025.1_all.deb",
                layout.archiveKeyringPackage, false);
        copyPrivateAsset(deContext, "bfu/bootstrap/SOURCES.lock",
                layout.sourceLock, false);
        copyPrivateAsset(deContext,
                "bfu/codec-test/avc-baseline-128x96-10fps.h264",
                layout.codecTestVector, false);
        copyPrivateAsset(deContext,
                "bfu/codec-test/avc-baseline-128x96-10fps.properties",
                layout.codecTestMetadata, false);
        copyPrivateAsset(deContext,
                "bfu/codec-test/avc-baseline-1280x720-30fps-30f.h264",
                layout.codec720pTestVector, false);
        copyPrivateAsset(deContext,
                "bfu/codec-test/avc-baseline-1280x720-30fps-30f.properties",
                layout.codec720pTestMetadata, false);
        copyPrivateAsset(deContext,
                "bfu/codec-test/avc-high-1920x1080-30fps-60f.h264",
                layout.codec1080pTestVector, false);
        copyPrivateAsset(deContext,
                "bfu/codec-test/avc-high-1920x1080-30fps-60f.properties",
                layout.codec1080pTestMetadata, false);
        copyPrivateAsset(deContext, "bfu/install-debian-rootfs.sh",
                layout.rootfsInstallerScript, true);
        copyPrivateAsset(deContext, "bfu/configure-debian-systemd.sh",
                layout.systemdConfiguratorScript, true);
        copyPrivateAsset(deContext, "bfu/configure-docker-network.sh",
                layout.dockerNetworkConfiguratorScript, true);
        copyPrivateAsset(deContext, "bfu/configure-host-usb.sh",
                layout.hostUsbConfiguratorScript, true);
        copyPrivateAsset(deContext, "bfu/dawnshell-codec-ffmpeg.py",
                layout.codecFfmpegAdapterScript, true);
        ensurePrivateFile(layout.lifecycleLog);
        return layout;
    }

    static String executeDirectBootProbe(Layout layout) throws IOException, InterruptedException {
        ProcessBuilder builder = new ProcessBuilder(layout.testScript.getAbsolutePath());
        builder.directory(layout.home);
        builder.redirectErrorStream(true);
        Map<String, String> environment = builder.environment();
        environment.clear();
        environment.put("HOME", layout.home.getAbsolutePath());
        environment.put("PATH", layout.bin.getAbsolutePath() + ":/system/bin:/system/xbin");
        environment.put("TMPDIR", layout.tmp.getAbsolutePath());

        Process process = builder.start();
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (output.length() > 0) output.append("; ");
                output.append(line);
            }
        }
        int exitCode = process.waitFor();
        if (exitCode != 0) {
            throw new IOException("DE executable probe exited with " + exitCode + ": " + output);
        }
        return output.toString();
    }

    private static void ensureDirectory(File directory) throws IOException {
        if (!directory.isDirectory()
                && !directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("Failed to create directory " + directory);
        }
        setPrivateMode(directory, true);
    }

    private static void writePrivateFile(File file, String contents, boolean executable)
            throws IOException {
        File temporary = new File(file.getParentFile(), file.getName() + ".new");
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(contents.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        setPrivateMode(temporary, executable);
        if (file.exists() && !file.delete()) {
            throw new IOException("Failed to replace " + file);
        }
        if (!temporary.renameTo(file)) {
            throw new IOException("Failed to install " + file);
        }
        setPrivateMode(file, executable);
    }

    private static void ensurePrivateFile(File file) throws IOException {
        if (!file.exists()) {
            try (FileOutputStream output = new FileOutputStream(file, false)) {
                output.getFD().sync();
            }
        }
        if (!file.isFile()) throw new IOException("Expected a regular file: " + file);
        setPrivateMode(file, false);
    }

    private static void verifyRuntimeProperties(File file,
                                                BfuArchitecture architecture)
            throws IOException {
        StringBuilder value = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(file), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (value.length() > 4_096) {
                    throw new IOException("BFU runtime metadata is unexpectedly large");
                }
                value.append(line).append('\n');
            }
        }
        String metadata = value.toString();
        if (!metadata.contains("android_abi=" + architecture.androidAbi + "\n")
                || !metadata.contains("debian_architecture="
                + architecture.debianArchitecture + "\n")
                || !metadata.contains("android_api=24\n")
                || !metadata.contains("dawnshell_codec_protocol=1\n")) {
            throw new IOException("BFU runtime metadata does not match the device ABI");
        }
    }

    private static void copyPrivateAsset(Context context, String assetPath, File file,
                                         boolean executable) throws IOException {
        File temporary = new File(file.getParentFile(), file.getName() + ".new");
        try (InputStream input = context.getAssets().open(assetPath);
             FileOutputStream output = new FileOutputStream(temporary, false)) {
            byte[] buffer = new byte[8_192];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            output.getFD().sync();
        }
        setPrivateMode(temporary, executable);
        if (file.exists() && !file.delete()) {
            throw new IOException("Failed to replace " + file);
        }
        if (!temporary.renameTo(file)) {
            throw new IOException("Failed to install " + file);
        }
        setPrivateMode(file, executable);
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setPrivateMode(File file, boolean executable) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
        if (executable) file.setExecutable(true, true);
    }
}
