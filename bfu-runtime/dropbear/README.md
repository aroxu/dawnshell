# Dropbear build requirements

[한국어 문서](README.ko.md)

Pinned candidate source: Dropbear 2026.94, matching the analyzed Termux package.

Before this directory produces an artifact, the build must prove:

- reproducible `arm64-v8a` PIE output with recorded source SHA-256;
- no DT_NEEDED dependency outside the intended Android system runtime, or a
  documented static-PIE result that works on API 36/kernel 4.4;
- no password/PAM/shadow/keyboard-interactive code path;
- no Termux prefix, `/data/data/com.termux`, or fixed `/data/user_de/0` string;
- runtime-supplied host key, authorized-keys, pid, home, shell, and port paths;
- successful execution from `nativeLibraryDir` and, for comparison, DE `filesDir`;
- license/source notices packaged with the APK.
