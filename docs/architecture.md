# DawnShell architecture

[한국어](architecture.ko.md) · [Glossary](glossary.md)

DawnShell is a standalone Android app with its own UID. Android's isolation model
is documented in the [AOSP app sandbox guide](https://source.android.com/docs/security/app-sandbox).

## Boot flow

```text
LOCKED_BOOT_COMPLETED
  -> BootReceiver
  -> BfuBootstrapService foreground service
  -> verify DE storage and pre-authorized root
  -> validate Debian rootfs
  -> prepare namespaces and cgroups
  -> start systemd as Debian PID 1
  -> start OpenSSH

USER_UNLOCKED
  -> record the event
  -> keep the existing Debian instance running
```

The receiver and service are Direct-Boot-aware as required by
[Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot#request_access).

## Storage boundaries

App Device Encrypted (DE) storage contains only boot settings, public keys,
runtime files, markers, and logs. It is located through
`createDeviceProtectedStorageContext()`; see the
[Context API](https://developer.android.com/reference/android/content/Context#createDeviceProtectedStorageContext()).

App Credential Encrypted (CE) storage contains the SSH client private key and is
used only after first unlock. The boot gate verifies that app CE remains
inaccessible during BFU. Debian's complete rootfs is held separately at the fixed
root-only path `/data/local/debian`.

See the [AOSP FBE guide](https://source.android.com/docs/security/features/encryption/file-based)
for the platform storage model.

## Bootstrap runtime

The APK contains source-built BusyBox, `pkgdetails`, statically linked `gpgv`,
Debian archive keys, and a namespace launcher for `armeabi-v7a`, `arm64-v8a`, and
`x86_64`. The installer verifies Debian Release signatures, indexes, and package
hashes before publishing a rootfs.

## Root boundary

Magisk approval is obtained while Android is unlocked and must be permanent.
Root helpers accept fixed operation IDs and fixed paths, avoid secrets in command
lines and logs, never remount Android's host `/data`, and revalidate every target
before stop or deletion.

## systemd environment

Private mount, PID, UTS, and cgroup namespaces isolate Debian's filesystem,
process IDs, hostname, and delegated resource view. The network namespace remains
shared with Android so existing Wi-Fi, mobile, VPN, and USB Ethernet interfaces
are available without emulation.

The cgroup policy probes a delegated v2 subtree and device BPF first. If load or
attach fails, it cleans every probe resource and falls back to isolated cgroup v1
`devices` and `name=systemd` views. Android's global hierarchy is never exposed
for Debian to modify.

USB passthrough is a DE-backed, default-off launch policy. Off mode overmounts
Debian's `/dev/bus/usb` with an empty read-only filesystem and denies character
major 189 using cgroup-device BPF on v2 or `devices.deny` on v1. Direct mode
retains the shared `/dev` USB view and Android driver bindings. Exclusive mode
uses the same raw view, scans sysfs every two seconds, and unbinds only interfaces
matching the saved `VID:PID` allowlist. The supervisor records each detached
interface and rebinds it in reverse order after Debian PID 1 exits. Hot-plug is
handled without restarting Debian. Cgroup policy remains limited to DawnShell's
delegated subtree; exclusive driver unbinding is necessarily host-wide and is
therefore a separately warned, explicit option.

## Hardware video codec bridge

Hardware video acceleration does not pass GPU device nodes into Debian. A
separate Direct-Boot-aware Android `:codec` process uses the public `MediaCodec`
API and will broker Debian requests over local IPC. It is isolated from Debian
systemd and SSH, so a vendor codec failure cannot terminate the server
lifecycle. `USER_UNLOCKED` does not stop it.

The implementation now includes the capability probe, root-peer-authenticated
local protocol, static clients for all three ABIs, bounded socket/`memfd`
transport, H.264 decode/encode, and H.264/HEVC Surface transcoding. Android 10
(API 29) and newer use platform hardware, software-only, and vendor flags;
Android 7–9 use conservative known-name classification. Session statistics
verify keyframes, timestamps, EOS, shared-memory use, and zero CPU YUV frames on
the Surface path. There is no silent software fallback. Status, logs, and the
capability JSON live under the app's DE `hardware-codec/` directory.

## SSH keys

The app generates an Ed25519 key pair after unlock. The private half stays in app
CE; only the public half is copied to DE and Debian. Private-key export occurs
only after explicit user action.

## Duplicate prevention

Boot ID, supervisor PID, process identity, and namespace checks prevent duplicate
Debian instances. Stale state is removed only after the corresponding process has
been proven absent or unrelated.

## Related documents

- [Glossary](glossary.md)
- [Security model](security.md)
- [Debian systemd](debian-systemd.md)
- [Testing](testing.md)
