# DawnShell glossary

[한국어](glossary.ko.md)

[Project home](../README.md) · [Installation guide](installation.md) ·
[User manual](user-guide.md)

This glossary expands the abbreviations used by DawnShell and links to official
Google or AOSP documentation where the term is part of Android.

## Android boot and storage

- **BFU — Before First Unlock:** the period after reboot and before the user
  first enters a PIN, pattern, or password.
- **AFU — After First Unlock:** the period after that first successful unlock.
- **Direct Boot:** Android's mode for running approved app components before the
  first unlock. See [Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot).
- **FBE — File-Based Encryption:** Android's file-based encryption model. See
  [the AOSP FBE guide](https://source.android.com/docs/security/features/encryption/file-based).
- **DE — Device Encrypted storage:** storage available during Direct Boot. Keep
  only data that is genuinely needed before unlock here.
- **CE — Credential Encrypted storage:** storage opened after the user's first
  unlock. See [Google's DE/CE explanation](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted).
- **`LOCKED_BOOT_COMPLETED`:** the Android broadcast sent after boot while the
  user remains locked. See [the Intent API](https://developer.android.com/reference/android/content/Intent#ACTION_LOCKED_BOOT_COMPLETED).
- **`USER_UNLOCKED`:** the broadcast sent after the first unlock. DawnShell
  records it without stopping the running Debian instance.

## App and build terms

- **AOSP — Android Open Source Project:** Google's open Android platform project
  and the source of the official `source.android.com` platform documentation.
- **APK — Android Package:** an installable Android application file. See
  [Android application fundamentals](https://developer.android.com/guide/components/fundamentals).
- **API — Application Programming Interface:** the contract used to call
  platform features. API 24 corresponds to Android 7.0.
- **ABI — Application Binary Interface:** the native binary contract for a CPU.
  DawnShell supports `armeabi-v7a`, `arm64-v8a`, and `x86_64`. See
  [Google's Android ABI guide](https://developer.android.com/ndk/guides/abis).
- **ADB — Android Debug Bridge:** Google's command-line device and debugging
  tool. It is optional for DawnShell. See [the ADB guide](https://developer.android.com/tools/adb).
- **UID — User Identifier:** the Linux identity Android assigns to an app for
  isolation. See [the AOSP app sandbox guide](https://source.android.com/docs/security/app-sandbox).
- **APK signing:** the cryptographic identity used for installation and updates.
  See [Google's app-signing guide](https://developer.android.com/studio/publish/app-signing).
- **CPU — Central Processing Unit:** the processor that executes instructions.
  ARM and x86 are different instruction families; ARM64 means 64-bit ARM.
- **SDK / NDK — Software Development Kit / Native Development Kit:** the Android
  app/API toolset and the C/C++ native-code toolset. See
  [Google's NDK guide](https://developer.android.com/ndk/guides).
- **JDK — Java Development Kit:** the Java compiler and runtime tools used by the
  Android build.
- **PIE — Position-Independent Executable:** a binary that does not depend on a
  fixed memory address.
- **SHA-256 — Secure Hash Algorithm 256-bit:** a file-content digest used to
  detect changes and verify downloads.
- **UI — User Interface:** the screens, buttons, and menus a user operates.
- **URL — Uniform Resource Locator:** a web page or download address.
- **ROM — Read-Only Memory:** in Android community usage, the installed vendor or
  custom Android operating-system image.
- **GNU / GPL / LGPL / MIT:** GNU is a free-software project; GPL and LGPL are GNU
  open-source licenses, while MIT is a concise permissive open-source license.

## Debian and remote access

- **rootfs — root file system:** Debian's complete directory tree, stored at
  `/data/local/debian`.
- **chroot — change root:** a Linux mechanism that changes the `/` directory a
  process sees. It is not a virtual machine.
- **PID — Process Identifier:** a number identifying a process. Debian sees its
  `systemd` as PID 1 inside the private PID namespace.
- **systemd:** Debian's service and boot manager.
- **SSH — Secure Shell:** an encrypted remote-shell protocol. DawnShell accepts
  public-key authentication only.
- **OpenSSH:** the SSH implementation that provides the `sshd` server and `ssh`
  client.
- **D-Bus — Desktop Bus:** the message bus used by Linux services and systemd.

## Kernel and network terms

- **TCP / IP — Transmission Control Protocol / Internet Protocol:** IP addresses
  and routes packets; TCP provides an ordered connection. TCP 22 is SSH's default
  listening port.
- **VPN — Virtual Private Network:** a virtual private connection over another
  network. Tailscale provides VPN-style connectivity.
- **USB — Universal Serial Bus:** a standard for connecting devices, including
  USB Ethernet adapters.
- **NIC — Network Interface Controller:** a Wi-Fi, mobile, or USB Ethernet
  network interface.
- **TUN — Network TUNnel:** a virtual network device commonly used by VPNs.
- **NAT — Network Address Translation:** address translation often configured by
  container bridges.
- **cgroup — control group:** a Linux mechanism for process resource and device
  policy. DawnShell probes v2 first and can fall back to v1.
- **BPF / eBPF — Berkeley Packet Filter / extended BPF:** verified programs that
  run in the kernel. DawnShell probes device-policy support before selecting its
  cgroup v2 path.
- **namespace:** a Linux isolation view for resources such as mounts, PIDs, host
  names, and networking.
- **UTS — UNIX Time-sharing System namespace:** the namespace that isolates host
  and domain names.
- **SELinux — Security-Enhanced Linux:** mandatory access control used by Android
  to strengthen app and service isolation. See
  [the AOSP app sandbox guide](https://source.android.com/docs/security/app-sandbox).
