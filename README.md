# DawnShell

[한국어](README.ko.md) · [Documentation](docs/README.md) · [Releases](https://github.com/aroxu/dawnshell/releases)

[![Build and release](https://github.com/aroxu/dawnshell/actions/workflows/build.yml/badge.svg)](https://github.com/aroxu/dawnshell/actions/workflows/build.yml)

**DawnShell starts a Debian 13 server on rooted Android before the first unlock
after reboot.** OpenSSH is reachable during BFU, and the same Debian `systemd`
instance keeps running after Android is unlocked.

```text
Android boot
  → LOCKED_BOOT_COMPLETED
  → verified root + Device Encrypted runtime
  → Debian 13 systemd
  → public-key-only OpenSSH on TCP 22

First unlock
  → record USER_UNLOCKED
  → keep the existing Debian and SSH instance running
```

Package: `me.aroxu.dawnshell`

> DawnShell requires permanent root permission. Debian shares Android's kernel
> and network and is not a fully isolated virtual machine. Read the
> [security model](docs/security.md) before exposing services or enabling
> high-risk compatibility options.

## Start here

New users should follow these pages in order:

1. [Installation guide](docs/installation.md) — install the APK, approve root,
   install Debian, configure SSH, and prove the first BFU boot.
2. [User manual](docs/user-guide.md) — daily controls, SSH, accounts, USB,
   hardware video acceleration, Docker, logs, backup, and removal.
3. [Troubleshooting](docs/troubleshooting.md) — symptom-based checks and safe
   diagnostic commands.

The [documentation home](docs/README.md) provides a task-based map of every
user, operations, and developer guide. Abbreviations are expanded in the
[glossary](docs/glossary.md).

## Features

- Debian 13 Trixie rootfs installation from pinned, verified upstream material
- Android Direct Boot startup through `LOCKED_BOOT_COMPLETED`
- Debian `systemd`, D-Bus, and public-key-only OpenSSH during BFU
- One persistent Debian instance across `USER_UNLOCKED`
- Source-built bootstrap runtime for `armeabi-v7a`, `arm64-v8a`, and `x86_64`
- Shared native Android networking, including Wi-Fi, mobile data, VPN, and USB
  Ethernet
- Optional raw USB sharing and VID:PID-scoped exclusive interface passthrough
- Runtime cgroup v2 probing with a validated cgroup v1 fallback
- Managed Docker host-network and host-IPC compatibility policies
- Experimental AVC/HEVC hardware decode, encode, Surface transcode, live HLS,
  and USB-webcam encoding through Android MediaCodec
- `gsmi` monitoring that separates 3D GPU state from video-codec activity
- Material 3 management UI, live selectable logs, generated SSH keys, local
  account password controls, and guarded rootfs removal

## Requirements

| Requirement | Why it is needed |
| --- | --- |
| Android 7.0 / API 24 or newer | Direct Boot and Device Encrypted storage APIs |
| File-Based Encryption | Separates pre-unlock DE from post-unlock CE data |
| Magisk or compatible `su` | Starts and manages the Debian namespaces and rootfs |
| Permanent DawnShell root approval | BFU cannot display an interactive root prompt |
| `armeabi-v7a`, `arm64-v8a`, or `x86_64` | ABIs included in the APK |
| A BFU-capable network path | Required only for remote access before unlock |

Some ROMs do not restore Wi-Fi until first unlock. DawnShell keeps SSH listening,
but it cannot unlock network credentials that Android withholds.

## Safe defaults

| Setting | Default | Meaning |
| --- | --- | --- |
| Direct Boot Debian bootstrap | Off until enabled | No automatic BFU server before explicit setup |
| BFU CE-readable override | Off | Startup fails closed if app CE is readable before unlock |
| cgroup policy | Automatic v2 → v1 | Uses v2 only after capability probes succeed |
| Docker networking | Host network only | Avoids Docker changes to Android-global firewall and routes |
| Docker host IPC compatibility | On | Avoids private IPC/mqueue failures on affected kernels; reduces container isolation |
| Raw USB access | Off | Blocks `/dev/bus/usb` and USB character major 189 only |
| Hardware video codec bridge | Off | Enables experimental MediaCodec work only after user opt-in |

Docker bridge, exclusive USB passthrough, and the CE-readable override can affect
the whole Android host. Their in-app warnings are part of the operating contract,
not optional background information.

## Storage and credentials

| Location | Available | Stored data |
| --- | --- | --- |
| App DE (Device Encrypted storage) | Before first unlock | Boot settings, public keys, logs, minimal verified runtime |
| App CE (Credential Encrypted storage) | After first unlock | Generated SSH client private key |
| `/data/local/debian` | Through pre-authorized root | Complete Debian rootfs, services, users, and local password hashes |

SSH listens on TCP 22 for user `debian`. Password authentication and direct root
login over SSH are disabled. The app can set a local root password so an
authenticated `debian` session can run `su root`.

Never place reusable auth keys, API tokens, or private SSH keys in data that must
be available before the PIN is entered.

## Build

The short path is:

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
./scripts/build-all.sh
```

Compilation uses `make -j"$(nproc)"` by default. Set `DAWNSHELL_BUILD_JOBS` to
limit parallel jobs. The debug APK is written as
`dist/dawnshell-app_v<version>+debug.apk`.

See [Build and release](docs/building.md) for dependencies, Windows/MSYS2,
individual checks, signing, CI behavior, and release packaging. The public debug
key is not a production signing identity.

## Documentation

### User guides

- [Documentation home](docs/README.md)
- [Installation guide](docs/installation.md)
- [User manual](docs/user-guide.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Glossary](docs/glossary.md)
- [FFmpeg hardware codec guide](docs/ffmpeg-hardware-codec.md)
- [FFmpeg MediaCodec syntax compatibility](docs/ffmpeg-mediacodec-compatibility.md)
- [`gsmi` accelerator status monitor](docs/gpu-status-tool.md)

### Operations and validation

- [Security model](docs/security.md)
- [Testing](docs/testing.md)
- [Progress](docs/progress.md)

### Architecture and development

- [Architecture](docs/architecture.md)
- [Debian rootfs installation](docs/rootfs-installation.md)
- [Debian systemd and SSH](docs/debian-systemd.md)
- [Hardware codec worker protocol](docs/hardware-codec-protocol.md)
- [Hardware codec implementation decision record](docs/media-codec-bridge-plan.md)
- [Build and release](docs/building.md)
- [Embedded bootstrap runtime](bfu-runtime/README.md)
- [Dropbear research note](bfu-runtime/dropbear/README.md)
- [Third-party notices](bfu-runtime/THIRD_PARTY_NOTICES.md)
- [License bundle](LICENSES/README.md)
- [Android dependency notices](LICENSES/ANDROID_DEPENDENCIES.md)

## License

DawnShell application code is licensed under the [MIT License](LICENSE).
Bundled tools and libraries retain their upstream licenses. Release packages
include corresponding source, license notices, build metadata, and SHA-256
checksums as described in [Build and release](docs/building.md).
