# DawnShell architecture

[한국어](architecture.ko.md) · [Documentation](README.md) · [Glossary](glossary.md)

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

Hardware video acceleration does not pass GPU device nodes into Debian. The
app-local `:codec` process is retained only for capability and file diagnostics.
Debian commands use an on-demand bionic NDK worker instead:

```text
static dawnshell-codec parent
  → inherited memfd request/response slots + two eventfds
  → private dawnshell-codec-worker child
  → AMediaCodec / AImageReader / ANativeWindow
```

There is no listening socket, descriptor transfer, registered service, or
persistent Debian codec daemon. One command owns one worker; parent death
terminates the child and releases its sessions. The private Debian mount
namespace exposes only read-only `/system`, `/apex`, and optional
`/linkerconfig` so the bionic worker can resolve Android runtime libraries.
App-private and normal app CE storage are not exposed.

The APK ships static clients and dynamic NDK workers for armv7, arm64, and
x86_64. The worker implements AVC/HEVC byte-buffer decode and encode plus
decoder-Surface-to-encoder-Surface transcoding. Hardware candidates are selected
from modern platform metadata or conservative Exynos and Qualcomm component
names. Software codecs are never silently selected. Session statistics verify
keyframes, timestamps, EOS, inherited shared-memory transport, and zero CPU YUV
frames on the Surface path. `USER_UNLOCKED` does not stop Debian; a worker is
created only when a codec command runs in either BFU or AFU.

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
