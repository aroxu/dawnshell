# DawnShell documentation

[한국어](README.ko.md) · [Project home](../README.md) · [Latest release](https://github.com/aroxu/dawnshell/releases/latest)

This is the documentation home for both first-time users and contributors. If
you are installing DawnShell for the first time, follow only the **First setup
path** below.

> **Read this first**
>
> DawnShell requires root. Debian shares Android's kernel and network and is not
> a fully isolated virtual machine. Prepare an independent recovery path before
> enabling Docker bridge networking, exclusive USB passthrough, or the unsafe CE
> override.

## First setup path

| Step | Action | Success signal |
| ---: | --- | --- |
| 1 | Follow the [installation guide](installation.md) to install the APK and approve root. | The root result contains `uid=0`. |
| 2 | Save BFU settings and install Debian 13. | The install log ends with `INSTALL_SUCCEEDED`. |
| 3 | Configure systemd and SSH. | The configuration log ends with `CONFIGURE_SUCCEEDED`. |
| 4 | Export the SSH private key and connect. | You log in as `debian`. |
| 5 | Reboot, stay locked, and connect again. | SSH works during BFU and survives first unlock. |

Use the [user manual](user-guide.md) for routine operation and the
[troubleshooting guide](troubleshooting.md) when a step fails.

## Find a task

| I want to… | Read… |
| --- | --- |
| Install DawnShell and prove BFU SSH | [Installation guide](installation.md) |
| Understand every app control | [User manual](user-guide.md) |
| Diagnose a specific error | [Troubleshooting guide](troubleshooting.md) |
| Look up an abbreviation | [Glossary](glossary.md) |
| Use a USB device from Debian | [USB sharing and passthrough](user-guide.md#5-usb-sharing-and-passthrough) |
| Run Docker safely | [Docker](user-guide.md#8-docker) |
| Use H.264/HEVC hardware acceleration | [FFmpeg hardware codec guide](ffmpeg-hardware-codec.md) |
| Understand `-hwaccel mediacodec` compatibility | [FFmpeg MediaCodec compatibility](ffmpeg-mediacodec-compatibility.md) |
| Interpret `gsmi` | [Accelerator status monitor](gpu-status-tool.md) |
| Build or release the app | [Build and release](building.md) |
| Validate a physical device | [Testing](testing.md) |

## User guides

| Document | Covers |
| --- | --- |
| [Installation](installation.md) | Download verification, root approval, Debian setup, SSH key export, first BFU test |
| [User manual](user-guide.md) | Every app section, lifecycle, SSH, accounts, USB, codecs, Docker, logs, removal |
| [Troubleshooting](troubleshooting.md) | Boot, root, install, SSH, Docker, USB, and codec failure playbooks |
| [Glossary](glossary.md) | BFU, AFU, DE, CE, rootfs, cgroups, namespaces, and other terms |
| [FFmpeg hardware codec](ffmpeg-hardware-codec.md) | File conversion, audio copy, HLS, USB webcams, automatic wrappers, raw pipelines |
| [FFmpeg MediaCodec compatibility](ffmpeg-mediacodec-compatibility.md) | Accepted upstream syntax, supported options, and fallback rules |
| [`gsmi` accelerator monitor](gpu-status-tool.md) | Reading 3D GPU and video-codec activity separately |

## Operations and validation

| Document | Covers |
| --- | --- |
| [Security model](security.md) | Storage, root, SSH keys, Docker, USB, and codec trust boundaries |
| [Testing](testing.md) | BFU/AFU, five boots, networking, USB, Docker, and codec validation |
| [Progress](progress.md) | Implemented features, completed device checks, remaining validation |

## Architecture and development

| Document | Covers |
| --- | --- |
| [Architecture](architecture.md) | Boot flow, storage boundaries, namespaces, cgroups, duplicate prevention |
| [Rootfs installation](rootfs-installation.md) | Embedded tools, signature/hash verification, atomic publication, failure preservation |
| [Debian systemd and SSH](debian-systemd.md) | Runtime mounts, PID 1, networking, SSH policy, stop and restart |
| [Hardware codec worker protocol](hardware-codec-protocol.md) | `memfd`/`eventfd`, wire format, hardware selection, limits |
| [Hardware codec decision record](media-codec-bridge-plan.md) | Why the final private-worker design was selected and what remains out of scope |
| [Build and release](building.md) | Local build, parallel jobs, CI, signing, release contents |

## Licensing and notices

| Document | Covers |
| --- | --- |
| [License bundle](../LICENSES/README.md) | Licenses shipped in the APK and release obligations |
| [Android dependency notices](../LICENSES/ANDROID_DEPENDENCIES.md) | Gradle-packaged Android library license notices |
| [Embedded runtime notices](../bfu-runtime/THIRD_PARTY_NOTICES.md) | Native tools, Debian material, and source correspondence |

## Conventions

- Replace `PHONE_IP` with the phone's current address.
- Replace `<version>` with the release version being installed.
- Commands beginning with `sudo` need Debian root privileges.
- **Bold text** names an app control.
- BFU is the period before the first unlock after reboot; AFU is after it.

Do not copy shell prompt characters (`$` or `#`). A trailing `\` means the
command continues on the next line.

## Reporting a problem

1. Run the matching section in the [troubleshooting guide](troubleshooting.md).
2. Open the relevant in-app live log and copy the complete output.
3. Include Android version, CPU ABI, DawnShell version, selected options, and
   exact reproduction steps.
4. Remove passwords, SSH private keys, API tokens, and reusable VPN auth keys.
