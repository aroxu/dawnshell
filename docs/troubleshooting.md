# DawnShell troubleshooting

[한국어](troubleshooting.ko.md) · [Documentation](README.md) · [User manual](user-guide.md) · [Testing](testing.md)

Use only the section matching the current symptom. Do not bypass signature,
checksum, or CE-isolation failures. Prepare an independent local recovery path
before changing Docker bridge or exclusive USB settings, and remove secrets
from every shared log.

## Collect the basics

Open the relevant stream under **Live logs** and copy the complete log. From
Debian, also collect:

```sh
uname -a
dpkg --print-architecture
cat /etc/debian_version
cat /proc/1/comm
systemctl is-active ssh.service
ip -brief address
```

When ADB is available after unlock:

```sh
adb shell getprop ro.build.version.release
adb shell getprop ro.product.cpu.abilist
adb shell dumpsys package me.aroxu.dawnshell
adb shell dumpsys user
```

ADB is not a BFU requirement. Some ROMs intentionally keep it unavailable
before first unlock, so validate BFU through SSH from another device.

## Root is denied or times out

Unlock Android, tap **Request / verify Magisk root permission**, verify package
`me.aroxu.dawnshell`, and select Magisk's permanent/forever approval. A valid
result contains `uid=0`, `root=true`, and `exit=0`. One-time approval cannot work
at the next locked boot because BFU cannot display Magisk's prompt.

## Debian does not start during BFU

Read **Direct Boot diagnostics** in this order:

1. `LOCKED_BOOT_COMPLETED received`
2. DE runtime verification
3. root probe
4. CE isolation probe
5. `/data/local/debian` rootfs probe
6. namespace/chroot probe
7. systemd and SSH health

| Result | Meaning and action |
| --- | --- |
| No boot broadcast | Open the app once, save/provision settings, and remove vendor auto-start or battery restrictions. |
| Root probe fails | Reapprove root permanently while unlocked. |
| `BFU_APP_CE_CONTENT_ACCESSIBLE` | The ROM exposed app CE before unlock. Keep the fail-closed default unless that platform risk is explicitly accepted. |
| Rootfs or ready marker missing | Complete rootfs installation and system configuration after unlock. |
| Namespace/cgroup failure | Return to automatic cgroup v2-to-v1 fallback and save again. |

Locking the screen after an unlock does not return the device to BFU. A valid
BFU test starts with a reboot and no first unlock.

## Debian installation fails

Copy the final `ERROR:` and `DEBOOTSTRAP_LOG_TAIL` from **Debian installation**.

| Failure | Action |
| --- | --- |
| Release signature | Check device time, HTTPS access, APK version, and embedded Debian keyring. Never bypass it. |
| SHA-256 mismatch | Retry over a stable network; do not accept the damaged package. |
| No space | Free internal storage. |
| `stat: invalid option -- c` | Update the APK and reprovision the embedded runtime. |
| Architecture mismatch | Verify Android ABI to Debian `armhf`/`arm64`/`amd64` mapping. |
| Final rootfs already exists | This is overwrite protection. Back up data and use the danger-zone removal flow when replacement is intended. |

Failed staging trees may be preserved as
`/data/local/debian.failed.<timestamp>`. Keep them until diagnosis is complete.

## systemd and SSH configuration fails

Configuration requires unlocked Android, a successful rootfs installation, a
visible generated public key, current root access, and no other setup operation.
Find the first failed `STAGE:` in **System configuration**.

When Debian is reachable:

```sh
systemctl --failed --no-pager
systemctl status dbus.service ssh.service --no-pager
journalctl -b -p warning --no-pager | tail -n 200
ss -ltnp | grep ':22 '
```

After rotating the client key, run configuration again to install the new
public key into `authorized_keys`.

## SSH is refused or rejects the key

`Connection refused` means the address responded but nothing is listening on
TCP 22. Check **Status** and **Lifecycle**, then:

```sh
systemctl status ssh.service --no-pager
ss -ltnp | grep ':22 '
journalctl -u ssh.service -n 100 --no-pager
ssh -vvv -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

`Permission denied (publickey)` means the server is reachable but the client key
does not match. Export the current key and reconfigure SSH after any rotation.
After a deliberate rootfs reinstall, remove only the old host-key entry:

```sh
ssh-keygen -R "[PHONE_IP]:22"
```

## Network is unreachable

If localhost SSH works but remote access does not, inspect Android's shared
interfaces and routes:

```sh
ip -brief link
ip -brief address
ip route
ip -6 route
```

DawnShell keeps SSH listening without an address and becomes reachable when
Android later brings up Wi-Fi, mobile data, or USB Ethernet. It cannot unlock
Wi-Fi credentials that a ROM keeps unavailable during BFU. Treat Tailscale
state as a BFU-available device credential and never store reusable auth keys
in setup scripts.

## croc waits forever before sending or receiving

`croc` reads non-TTY standard input before it considers an explicit filename.
An SSH command runner or process supervisor can leave that input pipe open
without writing anything, so croc stops immediately after its initial public-IP
message and appears to hang.

Re-run **Configure Debian 13 systemd + SSH** after updating DawnShell. The
configuration installs `/usr/local/bin/croc`, a narrow compatibility wrapper
that adds `--ignore-stdin` only for an explicit file, text payload, receive code,
or `CROC_SECRET` receive request. A bare piped transfer remains unchanged.

```sh
type -a croc
croc --debug --transport relay send file.bin
croc --debug --transport relay RECEIVE-CODE

# Intentional stdin transfer is still handled by upstream croc.
printf 'hello\n' | croc send

# Bypass DawnShell's compatibility wrapper for diagnosis. A manually
# installed binary is preserved in libexec; a Debian package uses /usr/bin.
/usr/local/libexec/dawnshell-croc-real --debug send file.bin
/usr/bin/croc --debug send file.bin
```

The wrapper preserves a manually installed `/usr/local/bin/croc` as
`/usr/local/libexec/dawnshell-croc-real`; a Debian package at `/usr/bin/croc`
is never moved. It does not choose a relay or store transfer secrets.
If a command still waits, add upstream's flag explicitly and retain the debug
output:

```sh
croc --debug --ignore-stdin --transport relay send file.bin
```

## Start, stop, or restart fails

Lifecycle requests are delivered immediately. Check the first failure in the
**Lifecycle** log and collect:

```sh
cat /proc/1/comm
systemctl is-system-running
systemctl --failed --no-pager
```

If DawnShell cannot prove that the current Debian PID 1 stopped, it fails closed
instead of killing an unverified process. Preserve PID, executable, namespace,
and boot-ID evidence; do not use broad `killall` or delete `/data` manually.

## Docker fails or disrupts Android networking

Return to automatic cgroup v2-to-v1 fallback, safe host-network-only mode, and
the enabled host-IPC compatibility wrapper, then tap **Apply Docker network
policy**.

```sh
docker info --format 'cgroup={{.CgroupDriver}} driver={{.Driver}}'
systemctl status docker.service containerd.service --no-pager
journalctl -u docker.service -n 200 --no-pager
docker run --rm --network host hello-world
```

The managed cgroup driver should be `cgroupfs`.

| Error | Meaning and action |
| --- | --- |
| nftables/iptables `Invalid argument` | The selected netfilter backend does not match the kernel. Return to host-only or use automatic backend probing. |
| `BPF_PROG_ATTACH ... operation not permitted` | Device BPF is unavailable. Allow automatic v1 fallback. |
| `/dev/mqueue ... device or resource busy` | The kernel's private IPC path is incompatible. Enable the host-IPC wrapper and reapply policy. |
| `failed to unshare remaining namespaces` | A dangerous namespace creation was blocked. Verify that the wrapper supplied host IPC. |
| `resolv.conf: operation not permitted` | Container mount setup conflicts with kernel/SELinux policy. Preserve the daemon log instead of retrying repeatedly. |

Bridge modes can alter Android-global firewall, NAT, forwarding, and routes. If
connectivity breaks, use the local screen or ADB to reapply host-only mode.

## USB visibility is surprising

**Off** blocks raw USBFS (`/dev/bus/usb`) and character major 189 only. Shared
sysfs may still show topology, and Android drivers may expose derived block,
network, serial, video, audio, or input devices.

```sh
ls -l /dev/bus/usb/*/* 2>/dev/null
ls -l /dev/block/sd* /dev/ttyUSB* /dev/ttyACM* /dev/video* 2>/dev/null
ip -brief link
```

Old kernels may lack the `rx_lanes` and `tx_lanes` attributes queried by newer
`lsusb -t`. Reapplying USB policy installs DawnShell's wrapper that suppresses
only those expected missing-file messages.

For an invalid `/dev/sdX1`, inspect the actual node instead of guessing its name:

```sh
lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINTS
stat -c '%F %t:%T %n' /dev/sdX /dev/sdX1 2>/dev/null
cat /proc/partitions
blkid /dev/sdX* 2>/dev/null
```

Never mount one filesystem from Android and Debian simultaneously. If an
exclusive-mode driver is not restored after an abnormal exit, unplug the device
or reboot.

## Hardware codec or FFmpeg fails

Enable the bridge, save/provision BFU runtime, and run Debian system
configuration again. Then check:

```sh
command -v dawnshell-codec dawnshell-ffmpeg dawnshell-hwencode
sudo dawnshell-codec health --format json
dawnshell-ffmpeg-integration status
```

A healthy worker reports `worker_state=ready`,
`transport=inherited_memfd_eventfd`, `public_listener=false`, and
`software_fallback=false`.

| Symptom | Action |
| --- | --- |
| `libandroidicu.so not found` | Reprovision and reconfigure from the latest APK. |
| `Connection refused` | An obsolete socket client remains; reconfigure Debian from the current APK. |
| `Broken pipe` | The worker exited first. Read the earlier linker/worker error and complete stderr. |
| `hardware bridge required but unavailable` | Inspect the route and `reason` with `plan-ffmpeg`. |
| BFU-only failure | Android media services may not be ready. Compare after unlock; Debian and SSH must remain healthy. |

```sh
/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg \
  -i input.mp4 -c:v h264_mediacodec output.mp4
```

Filters, CRF/preset, and multiple inputs are outside the automatic hardware
scope. An explicit `mediacodec` request intentionally fails instead of silently
using software. See the [FFmpeg hardware codec guide](ffmpeg-hardware-codec.md).

## `gsmi` reports 0% GPU

MediaCodec usually uses a dedicated video engine, not the 3D GPU. Therefore
`3D utilization=0%` with `Codec activity=active` is valid. If the kernel exposes
no VPU busy counter, `Codec utilization=unavailable` is also the truthful result.
See the [`gsmi` guide](gpu-status-tool.md).

## Share a safe report

Include DawnShell version/channel, Android version, CPU ABI, BFU or AFU state,
selected cgroup/Docker/USB/codec options, exact actions, expected result, and the
complete relevant log. Remove SSH private keys, passwords, API/VPN tokens, and
any private addresses or file names before posting it.
