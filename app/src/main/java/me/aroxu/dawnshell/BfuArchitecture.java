package me.aroxu.dawnshell;

import android.os.Build;

import java.io.IOException;

/** Maps an Android application ABI to the matching native Debian architecture. */
final class BfuArchitecture {

    final String androidAbi;
    final String debianArchitecture;

    private BfuArchitecture(String androidAbi, String debianArchitecture) {
        this.androidAbi = androidAbi;
        this.debianArchitecture = debianArchitecture;
    }

    static BfuArchitecture detect() throws IOException {
        for (String abi : Build.SUPPORTED_ABIS) {
            BfuArchitecture architecture = fromAndroidAbi(abi);
            if (architecture != null) return architecture;
        }
        throw new IOException("Unsupported Android ABI; supported ABIs are "
                + "armeabi-v7a, arm64-v8a, and x86_64");
    }

    static BfuArchitecture fromAndroidAbi(String abi) {
        if ("armeabi-v7a".equals(abi)) return new BfuArchitecture(abi, "armhf");
        if ("arm64-v8a".equals(abi)) return new BfuArchitecture(abi, "arm64");
        if ("x86_64".equals(abi)) return new BfuArchitecture(abi, "amd64");
        return null;
    }

    String assetDirectory() {
        return "bfu/bin/" + androidAbi;
    }
}
