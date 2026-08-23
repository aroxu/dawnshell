# DawnShell installation guide

[한국어](installation.ko.md)

[Project home](../README.md) · [User guide](user-guide.md) ·
[Latest release](https://github.com/aroxu/dawnshell/releases/latest)

This guide assumes an official release APK built by GitHub Actions and published
automatically from a version tag. Regular users should install the **signed APK
from GitHub Releases**, not a debug artifact from the `main` branch workflow.

## 1. Requirements

You need:

- Android 7.0/API 24 or newer with File Based Encryption (FBE);
- an `armeabi-v7a`, `arm64-v8a`, or `x86_64` device;
- Magisk or a compatible `su`, with permanent root authorization for DawnShell;
- an internet connection for Debian packages and sufficient internal storage;
- Wi-Fi or another network restored by the ROM before first unlock if remote BFU
  access is required.

DawnShell cannot start Debian without root. ADB permissions are not required for
installation or Direct Boot; ADB is an optional diagnostic path only. Resolve any
port conflict if another SSH daemon already owns TCP 22.

On Samsung and other vendor ROMs, exempt DawnShell from battery optimization,
sleep, and autostart restrictions where those controls exist. The Android ROM is
still responsible for bringing up a network interface and assigning an address
during BFU.

## 2. Download and verify an official release

1. Open [DawnShell Releases](https://github.com/aroxu/dawnshell/releases) and
   select the newest stable release.
2. Confirm that the release notes identify the build commit and assets.
3. Download at least these files into one directory:

```text
dawnshell-<version>.apk
SHA256SUMS
```

Each release also publishes the corresponding materials:

```text
dawnshell-<version>-<commit>-corresponding-source.tar.gz
dawnshell-<version>-<commit>-licenses.tar.gz
dawnshell-<version>-<commit>-build-info.txt
RELEASE_NOTES.md
```

On Linux or Termux, download all assets and verify them in that directory:

```sh
sha256sum -c SHA256SUMS
```

With the default macOS toolchain:

```sh
shasum -a 256 -c SHA256SUMS
```

On Windows PowerShell, calculate the APK hash and compare it with the matching
entry in `SHA256SUMS`:

```powershell
Get-FileHash .\dawnshell-0.2.0.apk -Algorithm SHA256
Get-Content .\SHA256SUMS
```

Replace the example filename with the actual release version. Do not install an
APK whose checksum does not match; download it again.

### Actions artifacts versus releases

- Branch, pull-request, and manually dispatched workflows may produce a debug
  artifact for testing. It uses a public debug key and is not intended for normal
  installation or updates.
- A `vMAJOR.MINOR.PATCH` tag build is signed with the repository's private release
  key and published as a GitHub Release only after all checks and a second
  checksum verification pass.
- Android cannot update an app with an APK signed by a different key. Moving from
  a debug or custom build to an official release may require uninstalling the old
  app, so export the SSH private key first.

## 3. Install the APK

Open the APK on the phone, temporarily permit “Install unknown apps” for that
browser or file manager, and install it. Revoke that permission afterward if it
is no longer needed.

Optional ADB installation:

```sh
adb install -r dawnshell-<version>.apk
```

An update signed by the same release key preserves app data and settings with
`-r`. A different certificate requires uninstalling and reinstalling. Removing
DawnShell deletes its CE/DE settings and generated client identity, but does not
automatically remove the separate `/data/local/debian` rootfs.

## 4. First launch and permanent Magisk authorization

Unlock Android and open DawnShell.

1. Tap **Request / verify Magisk root permission**.
2. Confirm that the dialog lists only the expected DawnShell package for the UID.
3. Select Magisk's **permanent/forever** authorization duration.
4. Confirm that the latest AFU result reports `exit=0`, `root=true`, and `uid=0`.

A one-time grant fails at cold-boot BFU because no authorization UI can be shown.
DawnShell cannot determine whether Magisk persisted the policy, so verify the
DawnShell entry in the Magisk manager as well.

## 5. Save Direct Boot settings and provision the runtime

Recommended initial settings:

- **Enable Direct Boot Debian bootstrap**: on
- **Allow BFU when this app's CE storage is readable**: off
- cgroup: **Automatic: cgroup v2, then v1 fallback (recommended)**
- Docker networking: **Safe host network only (recommended)**

Tap **Save BFU settings and provision runtime**. This writes non-secret settings,
the CE isolation sentinel and receipt, the device-ABI native tools, and the Debian
bootstrap inputs into app-owned Device Protected Storage. If an unsaved-settings
warning remains, save again before rebooting.

Do not enable the CE-readable override by default. Use it only when the newest
locked-state isolation probe actually records `TERMUX_CE_CONTENT_ACCESSIBLE` and
you understand and accept that ROM-level exposure.

## 6. Install the Debian 13 rootfs

1. Tap **Install Debian 13 Trixie rootfs**.
2. Approve the confirmation dialog.
3. Open **Logs → Debian installation** to watch progress.
4. Wait for status `SUCCEEDED` and a final `INSTALL_SUCCEEDED` log entry.

The installer uses ABI-matched tools bundled in the APK, verifies Debian Release
signatures and package hashes, builds under `/data/local/debian.installing`, and
atomically publishes only a validated tree as `/data/local/debian`. It never
overwrites an existing rootfs.

On failure, copy the complete installation log before deleting the app or staging
tree. The next attempt preserves an interrupted tree as
`/data/local/debian.failed.<timestamp>` for diagnostics.

## 7. Configure systemd and SSH

After the rootfs installation succeeds:

1. Confirm that the generated Ed25519 public key is visible in the app.
2. Tap **Configure Debian 13 systemd + SSH**.
3. Watch **Logs → System configuration** for APT, systemd, and OpenSSH output.
4. Require status `SUCCEEDED` and a final `CONFIGURE_SUCCEEDED` result.
5. Tap **Status** and verify systemd PID 1, D-Bus, `ssh.service`, TCP 22, and
   cgroup health.

The default SSH account is `debian` on TCP 22. Password authentication and root
SSH login remain disabled; only the public key generated by DawnShell is installed.

## 8. Export the SSH private key

For another computer, use **Export SSH private-key file**, transfer the file by a
trusted method, and restrict it to its owner:

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

For Termux on the same phone:

1. Tap **Copy Termux private-key import command**.
2. Accept the warning and immediately paste the one-line command into your own
   Termux session.
3. Tap **Copy SSH connect command** and run that command in Termux.

The clipboard item containing the private key is cleared after 120 seconds if it
has not changed. File export is still safer because another app may read the
clipboard while it exists.

## 9. Perform the first BFU test

After all configuration succeeds, reboot the phone and do not enter the PIN or
pattern. Connect from another device to the phone's BFU network address:

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

Run at least:

```sh
id
cat /proc/1/comm
systemctl is-system-running
systemctl is-active ssh.service
ip addr
uptime
```

`/proc/1/comm` should report `systemd`, and `ssh.service` should be `active`.
Unlock Android afterward and confirm that the existing SSH session and Debian
PID 1 continue without a restart. Unlocking does not stop DawnShell Debian.

## 10. Update DawnShell

1. Read `RELEASE_NOTES.md` and verify the new release checksums.
2. Install the APK, signed by the same release key, over the existing app.
3. Open DawnShell once while Android is unlocked.
4. Tap **Save BFU settings and provision runtime** again to publish updated assets.
5. Check status, then perform a planned Debian restart or cold-boot validation.

Keep a separate, protected copy of the client private key before updating. It
simplifies recovery from a signing mismatch or reinstall. The rootfs is separate
from the APK, but do not perform unsupported downgrades or in-place changes.

## Related documents

- Daily operation: [user guide](user-guide.md)
- Rootfs internals: [rootfs installation](rootfs-installation.md)
- Security assumptions and risks: [security model](security.md)
- Complete physical validation: [test plan](testing.md)
