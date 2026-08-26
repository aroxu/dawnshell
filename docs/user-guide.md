# DawnShell user manual

[한국어](user-guide.ko.md)

[Documentation](README.md) · [Installation guide](installation.md) ·
[Glossary](glossary.md) · [Troubleshooting](troubleshooting.md)

This manual covers daily operation after installation. Follow the
[installation guide](installation.md) first if Debian and SSH are not configured.

The home screen is ordered for one top-to-bottom initial setup.

| Screen order | Routine purpose |
| ---: | --- |
| 1 · Direct Boot | Approve root and save BFU startup policy |
| 2 · Debian setup | Install the rootfs and configure systemd/SSH |
| 3 · Server controls | Start, restart, inspect, or stop Debian |
| 4 · SSH access | Export, import, connect with, or rotate the client key |
| Accounts | Set local `debian` and `root` passwords |
| USB sharing and passthrough | Share raw USBFS or detach selected interfaces |
| Hardware video acceleration | Configure MediaCodec, tests, and FFmpeg tools |
| Kernel & Docker compatibility | Select cgroup and Docker network/IPC policy |
| Diagnostics and logs | Read BFU evidence and live operation output |
| Danger zone | Permanently remove the verified Debian rootfs |

Changing a switch is not always enough. Direct Boot and codec changes require
**Save and provision BFU runtime**, USB requires **Apply USB sharing policy**,
and Docker requires **Apply Docker network policy**.

## Core behavior

- BFU means Before First Unlock; AFU means After First Unlock.
- DawnShell starts Debian systemd and SSH during BFU.
- The same instance remains running after unlock.
- Debian shares the Android kernel and network and is not a fully isolated VM.

See the [glossary](glossary.md) for DE, CE, PID, rootfs, and other terms, or read
[Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot).

## 1. Direct Boot controls

**Enable Direct Boot Debian bootstrap** controls automatic startup on the next
cold boot. After changing it, tap **Save and provision BFU runtime**.

**Request / verify Magisk root permission** checks current root access. Magisk
must grant permanent approval because BFU cannot display a prompt.

**Refresh BFU probe results** reads evidence from the last locked boot; it does
not rerun the probe while Android is unlocked.

Keep the BFU CE-readable override disabled on a normal FBE device. It accepts an
already unsafe ROM condition; it does not repair encryption.

## 2. Debian setup and lifecycle

**Install Debian 13 Trixie rootfs** creates `/data/local/debian` without silently
overwriting a valid installation. **Configure Debian 13 systemd + SSH** prepares
systemd, D-Bus, OpenSSH, the `debian` account, the current public key, and boot
proof services. Both operations run only after Android is unlocked.

- **Start:** validate and start Debian systemd.
- **Restart:** gracefully stop and start a new instance.
- **Status:** check systemd, D-Bus, SSH, TCP 22, and cgroups.
- **Stop:** stop Debian services and SSH.

Unlocking Android never stops the running server.

## 3. SSH access

For another computer, export the SSH private-key file:

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

For a trusted local shell on the phone, run the copied local-shell key import
command once, then run the copied SSH connect command. The import command contains
the complete private key, so file export is safer.

Generating a new random client key permanently replaces the old identity. Back
up the old key, generate the replacement, rerun systemd + SSH configuration,
export the new key, and verify it before deleting old copies.

## 4. Accounts and root

The app can set local `debian` and `root` passwords. Passwords are passed directly
to Debian and are not stored in app settings, DE storage, or logs. SSH password
authentication remains disabled.

After connecting as `debian`:

```sh
su root
```

Enter the root password configured in the app. This root shell can affect the
Android device, so run only trusted commands.

To reboot the entire Android device:

```sh
reboot --check
reboot now
```

`systemctl reboot` is a namespace-isolation test path, not the Android reboot
command.

This `reboot` command is the only way to restart Android. Debian and the
containers it runs cannot ask the kernel to reboot directly, because some
kernels do not confine such a request to the container and restart the whole
device instead. That is what can otherwise reboot the phone when a Docker
container starts or is cleaned up.

## 5. USB sharing and passthrough

USB passthrough is disabled by default and takes effect on the next Debian start
or when **Apply USB sharing policy** restarts a running Debian. A stopped Debian
is not started by the apply action. USB Ethernet does not require this setting
because Debian already shares Android's network namespace.

On old kernels, Debian 13 `lsusb -t` may query newer `rx_lanes` and `tx_lanes`
sysfs attributes that do not exist. DawnShell installs a managed compatibility
wrapper when the USB policy is applied. It suppresses only those expected
`ENOENT` messages and preserves other USB diagnostics.

- **Direct passthrough** exposes `/dev/bus/usb`, propagates hot-plug, and leaves
  Android kernel drivers attached. Use this first for ordinary libusb inspection.
- **Exclusive passthrough** also unbinds every interface belonging to a device
  whose exact `VID:PID` is listed. Use commas or spaces, such as
  `0403:6001, 10c4:ea60`. At least one ID is mandatory. DawnShell scans for new
  matching devices and tries to restore detached drivers when Debian stops.

The **Off** setting is specifically a raw USBFS policy: it masks
`/dev/bus/usb` and denies character-device major 189. It does not stop Android's
kernel from enumerating USB hardware, so shared sysfs may still show the device.
Kernel drivers can also expose derived resources such as `/dev/block/sd*`, USB
Ethernet, `ttyUSB`/`ttyACM`, input, video, or audio nodes. Those resources are
outside the raw USBFS policy and require separate device-class isolation.

Inside Debian, inspect a connected device with:

```sh
ls -l /dev/bus/usb/*/* 2>/dev/null
lsusb 2>/dev/null || true
dmesg | tail -n 100
```

USB serial, storage, camera, audio, and input support still require the matching
Android kernel support. SELinux may deny access even to root. Exclusive mode can
disconnect Android input, storage, networking, ADB, or recovery access. Use a
disposable peripheral and independent recovery path; after an abnormal exit you
may need to unplug it or reboot. Never select the phone's internal USB/gadget
controller, and never mount one USB storage filesystem from both systems. A
Docker container must receive the node separately with `--device`; avoid
`--privileged`.

## 6. Hardware video acceleration

For complete commands, automatic integration, audio remuxing, and fallback
rules, see the [FFmpeg hardware codec guide](ffmpeg-hardware-codec.md).

Upstream FFmpeg spellings such as `-hwaccel mediacodec` and
`-c:v h264_mediacodec` work as well. Naming MediaCodec explicitly makes
hardware mandatory, so the command fails instead of silently using libx264.
See
[Upstream FFmpeg MediaCodec syntax compatibility](ffmpeg-mediacodec-compatibility.md).

Debian can run H.264/HEVC encoding and decoding on the device's dedicated video
codec instead of the CPU. This is not GPU passthrough: Debian only demuxes and
muxes containers, while an on-demand bionic NDK worker performs the codec work
and returns the result through inherited shared descriptors.

### Enabling it

1. Turn on **Enable hardware codec bridge at Direct Boot**.
2. Press **Save and probe hardware codecs**.
3. Run **Configure Debian 13 systemd + SSH** again.
4. Press **Download and run file-based hardware AVC decode self-test**.
5. Run `sudo dawnshell-codec health --format json` in Debian.

Configuration installs these commands in Debian.

| Command | Purpose |
| --- | --- |
| `dawnshell-ffmpeg` | Accepts ordinary FFmpeg command lines and routes them automatically |
| `dawnshell-hwdecode` | H.264/HEVC decoding |
| `dawnshell-hwencode` | Encodes raw I420 to H.264/HEVC |
| `dawnshell-hwtranscode` | Re-encodes H.264/HEVC to H.264 |
| `dawnshell-live-encode` | Live AVC encode from a USB webcam, HLS, RTSP, or file input |
| `dawnshell-codec-self-test` | Verifies the bridge |
| `gsmi` | Separates 3D GPU state from DawnShell codec activity |

The app's **file-backed hardware AVC decode self-test** installs `wget` and
`ca-certificates` with Debian `apt` when needed, then downloads the 1920x1080
H.264 Big Buck Bunny sample from test-videos.co.uk inside Debian. Android reads
the staged DE file directly with `MediaExtractor` and a conservatively selected
hardware `MediaCodec`. This app-local test uses no interprocess media transport;
the report must show `interprocess_media_bytes=0`. The first run can take longer
because it installs packages and downloads about 5 MB.

`dawnshell-codec-self-test` remains the separate advanced private-worker test.
If the file-backed test passes while that command fails, the failure is isolated
to worker launch or inherited memfd/eventfd transport rather than codec
availability.

### Automatic integration

`dawnshell-ffmpeg` takes the same arguments as `ffmpeg`. Commands the bridge can
reproduce exactly run on hardware; everything else is handed to the real FFmpeg
unchanged, so a filter or option is never silently dropped.

```sh
dawnshell-ffmpeg -i input.mp4 -c:v libx264 -b:v 3M output.mp4
dawnshell-ffmpeg -i input.mp4 output.yuv
```

Debian configuration enables the managed `/usr/local/bin/ffmpeg` integration by
default. Inspect, disable, or enable it without editing the symlink manually:

```sh
dawnshell-ffmpeg-integration status
sudo dawnshell-ffmpeg-integration disable
sudo dawnshell-ffmpeg-integration enable
hash -r
```

Because `/usr/local/bin` precedes `/usr/bin`, programs that call `ffmpeg` by name
find the bridge. A program that executes `/usr/bin/ffmpeg` always bypasses it.

Override the behaviour with an environment variable.

| Value | Behaviour |
| --- | --- |
| `auto` (default) | Hardware when possible, otherwise software |
| `off` | Always use the real FFmpeg |
| `require` | Fail instead of falling back to software |

```sh
DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg -i input.mp4 -c:v libx264 out.mp4
```

Use `require` when benchmarking so a silent software fallback cannot be mistaken
for a hardware result.

### What runs on hardware

- A single H.264 or HEVC video input.
- A supported AVC/HEVC MediaCodec output spelling, a compatible AVC alias, or a
  raw `.yuv`/`.i420` output.
- Even dimensions between 16 and 4096.
- `-b:v` within 1000..100000000.

These fall back to software: filters such as `-vf`, x264-specific options such as
`-crf` and `-preset`, multiple inputs, audio encoding/filtering, `-c:v copy`, and
codecs such as VP9 or AV1. ByteBuffer hardware encode can preserve the first
optional audio stream with `-c:a copy`.

```sh
sudo ffmpeg -y -i input.mp4 -c:a copy \
  -c:v h264_mediacodec -b:v 4M output.mp4
```

See [live HLS and USB-webcam encoding](ffmpeg-hardware-codec.md#live-hls-and-usb-webcam-encoding)
for streaming examples. Monitor an active job from another shell with:

```sh
gsmi --loop 1
```

### Verification

```sh
sudo dawnshell-codec health --format json
sudo dawnshell-codec-self-test
```

The reported backend names the codec that was actually selected. A software
codec is never chosen silently; the bridge fails with a clear error instead. A
codec failure never stops Debian or SSH.

If codec sessions fail during BFU, Android media services may not be ready yet.
Retry after unlocking to compare.

## 7. Kernel and cgroups

Keep the recommended **Automatic: cgroup v2 → v1 fallback** unless diagnosing a
specific kernel. Automatic mode adopts v2 only after a private delegated subtree
and device-BPF probe both succeed; it cleans the probe state before falling back
to v1. Force-v2 can prevent Debian from starting, while force-v1 is a legacy
diagnostic path. The selection applies on the next Debian start or restart.

## 8. Docker

The safe starting policy is **Safe host network only**:

```sh
docker info --format '{{.CgroupDriver}}'
docker run --rm --network host hello-world
```

The cgroup driver should be `cgroupfs`. DawnShell keeps Docker inside its
delegated hierarchy instead of asking Android-side systemd compatibility code to
create transient container scopes.

**Use host IPC for containers** is enabled by default. Some kernels panic during
private IPC namespace or mqueue setup. DawnShell blocks that dangerous creation,
and the managed wrapper:

- adds `--ipc=host` to `docker run` and `docker create` when IPC was not given;
- creates a temporary per-service `ipc: host` override for `docker compose`;
- preserves every explicit `--ipc` or `ipc:` value.

Host IPC weakens isolation by sharing IPC objects among Android, Debian, and the
container. Do not use it for untrusted containers. Tap **Apply Docker network
policy** after changing the option.

Bridge modes can alter Android-global firewall, NAT, forwarding, and routes and
disconnect Wi-Fi, mobile data, USB Ethernet, VPNs, Tailscale, or SSH. Prepare an
independent recovery path first. See [Docker troubleshooting](troubleshooting.md#docker-fails-or-disrupts-android-networking)
for common kernel errors.

## 9. Logs

The Logs screen provides app operations, Debian installation, system
configuration, USB, hardware codecs, compatibility, lifecycle, and Direct Boot
diagnostics. Readers
refresh once per second and support scrolling, selection, and copying. Do not add
private keys or passwords when sharing a log.

## 10. Networking

The SSH server listens on TCP 22 even before Android assigns an address. When
Android later brings up Wi-Fi, mobile data, or USB Ethernet, no Debian restart is
required.

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

Treat `tailscaled.state` as a device credential available before PIN entry. Do
not store reusable authentication keys in the BFU rootfs.

## 11. Backup and removal

Back up the exported SSH client key, important Debian configuration and user
data, package lists, and service configuration.

To remove Debian completely, stop it, confirm systemd is absent, open the danger
zone, choose permanent rootfs removal, complete both confirmations, type
`DELETE`, and verify `DEBIAN_ROOTFS_REMOVE_SUCCEEDED`. Then uninstall DawnShell
from Android settings if desired.

## When something fails

The separate [troubleshooting guide](troubleshooting.md) provides ordered checks
for boot, root, installation, SSH, networking, Docker, USB, and codecs. Include
the relevant complete live log, Android version, CPU ABI, BFU/AFU state, and
selected options in a report.

## Related documents

- [Installation guide](installation.md)
- [Documentation home](README.md)
- [Troubleshooting](troubleshooting.md)
- [Glossary](glossary.md)
- [Security model](security.md)
- [Architecture](architecture.md)
- [Testing](testing.md)
