# DawnShell installation guide

[한국어](installation.ko.md)

[Project home](../README.md) · [User manual](user-guide.md) ·
[Glossary](glossary.md) · [Latest release](https://github.com/aroxu/dawnshell/releases/latest)

This guide uses the signed APK from GitHub Releases. APK means Android Package,
the file installed on an Android device.

## 1. Check the requirements

- Android 7.0 / API 24 or newer
- File-Based Encryption (FBE)
- `armeabi-v7a`, `arm64-v8a`, or `x86_64`
- Magisk or a compatible `su`, with permanent approval for DawnShell
- Internet access and enough internal storage for Debian
- A ROM that restores a network connection before unlock if remote BFU access is
  required

See the [glossary](glossary.md) for every abbreviation and
[Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot)
for the platform requirements. ADB (Android Debug Bridge) is optional; see
[Google's ADB guide](https://developer.android.com/tools/adb).

Resolve any existing TCP 22 conflict before setup. On vendor ROMs, exclude
DawnShell from battery, sleep, and automatic-start restrictions.

## 2. Download and verify the release

Download these files from [DawnShell Releases](https://github.com/aroxu/dawnshell/releases):

```text
dawnshell-<version>.apk
SHA256SUMS
```

On Linux:

```sh
sha256sum -c SHA256SUMS
```

On macOS with the built-in tools:

```sh
shasum -a 256 -c SHA256SUMS
```

On Windows PowerShell:

```powershell
Get-FileHash .\dawnshell-0.3.0.apk -Algorithm SHA256
Get-Content .\SHA256SUMS
```

Do not install a file whose checksum differs. Ordinary workflow artifacts may be
debug-signed test builds; regular users should install a tagged Release APK.
See [Google's app-signing guide](https://developer.android.com/studio/publish/app-signing).

## 3. Install the APK

Open the APK on the phone and temporarily allow that browser or file manager to
install unknown apps. If ADB is already configured, this is equivalent:

```sh
adb install -r dawnshell-<version>.apk
```

An update normally needs the same signing key as the installed version.
Uninstalling DawnShell removes its DE/CE data and generated SSH client key, but
does not automatically remove `/data/local/debian`.

## 4. Grant permanent root access

While Android is unlocked:

1. Open DawnShell and tap **Request / verify Magisk root permission**.
2. Confirm that the request is from package `me.aroxu.dawnshell`.
3. Select Magisk's permanent or forever approval.
4. Confirm `exit=0`, `root=true`, and `uid=0` in the result.

BFU cannot display an approval prompt, so one-time approval is insufficient.

## 5. Save Direct Boot settings

Recommended initial values:

- Enable the Direct Boot Debian bootstrap.
- Keep the BFU CE-readable override disabled.
- Select automatic cgroup v2-to-v1 fallback.
- Select safe host-network-only Docker mode.

Tap **Save and provision BFU runtime**. This stores non-secret settings and the
ABI-specific runtime in Device Encrypted storage. Google explains why DE is
available before unlock and CE is not in its
[Direct Boot storage guide](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted).

## 6. Install Debian 13

1. Tap **Install Debian 13 Trixie rootfs** and confirm.
2. Open **Logs → Debian installation**.
3. Wait for `SUCCEEDED` and `INSTALL_SUCCEEDED`.

The installer verifies Debian Release metadata and package hashes in a staging
tree, then publishes only a valid result to `/data/local/debian`. Preserve the
log if installation fails.

## 7. Configure systemd and SSH

1. Confirm that the generated Ed25519 public key is visible.
2. Tap **Configure Debian 13 systemd + SSH**.
3. Open **Logs → System configuration**.
4. Wait for `SUCCEEDED` and `CONFIGURE_SUCCEEDED`.
5. Tap **Status** and confirm systemd, D-Bus, SSH, and TCP 22 are healthy.

The SSH account is `debian`. Password authentication and direct root login are
disabled; only the generated public key is accepted.

## 8. Export the SSH key

Use **Export SSH private-key file** for another computer:

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

For a trusted local shell on the same phone, copy and run the local-shell key
import command, then copy and run the SSH connect command. The import command
contains the complete private key, so file export is safer.

## 9. Test BFU startup

Reboot without entering the PIN, pattern, or password. From another device:

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

Then check:

```sh
id
cat /proc/1/comm
systemctl is-active ssh.service
ip addr
uptime
```

`/proc/1/comm` should be `systemd`, and SSH should be `active`. Unlock Android
and confirm that the existing session and Debian PID 1 remain unchanged.

## 10. Update

Verify the new Release, install an APK signed by the same key, open DawnShell
after unlock, and tap **Save and provision BFU runtime** again. Back up the
exported SSH private key before updates.

## Next documents

- [User manual](user-guide.md)
- [Glossary](glossary.md)
- [Security model](security.md)
- [Rootfs installation details](rootfs-installation.md)
- [Testing](testing.md)
