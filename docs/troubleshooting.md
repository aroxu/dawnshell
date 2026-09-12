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

Some ROMs deliver boot completion after the user is already unlocked. In that
case DawnShell starts an already-provisioned Debian rootfs from
`BOOT_COMPLETED`, without repeating the BFU probes. A credential-protected boot
uses `LOCKED_BOOT_COMPLETED` and starts Debian after the BFU root, CE-isolation,
rootfs, and namespace checks pass.

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

## Configuration stalls at "Setting up openssh-server" or the machine ID

Some Android kernels, including several LineageOS builds on a 4.4 base, carry a
close_range(2) backport that walks every descriptor number in the requested
range instead of stopping at the end of the process descriptor table. glibc
implements closefrom(3) as close_range(lowfd, ~0U, 0), so one call asks the
kernel to walk 2^31-1 descriptors. Measured on an affected device this costs
about 50 ns per descriptor, which turns a single closefrom(3) call into roughly
two minutes of uninterruptible kernel time.

sshd, systemd, and D-Bus all call closefrom(3) while their packages are
configured, so the symptom looks like a hang at one of these lines:

    Setting up openssh-server (...) ...
    Creating config file /etc/ssh/sshd_config with new version
    Initializing machine ID from D-Bus machine ID.

The same quirk breaks short-timeout actions. Changing the Debian or root
password runs chpasswd, which also calls closefrom(3), so the app reports:

    account=root command=su exit=-2 timeout=true
    output=read interrupted by close() on another thread

Measured on an affected device, that one command took over 60 seconds without
the guard and one second with it.

Tools that never call closefrom(3), such as ssh-keygen, stay instant, which is
why the slowness looks selective.

DawnShell measures the kernel once per Debian entry point and, when it is
affected, installs a seccomp filter that reports ENOSYS for close_range(2).
glibc then falls back to scanning /proc/self/fd, which closes the same
descriptors in microseconds. The filter is inherited, so apt, dpkg, sshd, and
systemd are all covered. A successful installation logs:

    dawnshell-fdguard: this kernel walks the whole close_range(2) range;
    reporting ENOSYS so closefrom(3) uses /proc/self/fd

On an affected device this changed `dpkg-reconfigure openssh-server` from over
ten minutes to about three seconds.

Confirm the kernel behaviour yourself from a root shell. The cost should stay
flat as the range grows; a rising number means the kernel is affected:

```sh
for last in 1000 100000 10000000; do
  printf 'last_fd=%s ' "$last"
  TIMEFORMAT=%R
  time perl -e "syscall(436, 3, $last, 0)"
done
```

Override the automatic decision only for diagnosis:

```sh
DAWNSHELL_CLOSE_RANGE_GUARD=off    # never install the filter
DAWNSHELL_CLOSE_RANGE_GUARD=force  # install without measuring
```

## systemd stays "degraded" and services report "Required key not available"

The app can report the start as failed even though SSH answers. The health line
then shows `system_state=degraded`, and these units are failed:

    ldconfig.service                       Rebuild Dynamic Linker Cache
    systemd-journal-catalog-update.service Rebuild Journal Catalog
    systemd-update-done.service            Update is Completed

Their journal entries all end the same way:

    Failed to write "/etc/.updated": Required key not available

/data is protected by fscrypt. On this kernel generation the policies are
version 1, which means the encryption key is looked up in the calling process's
own keyrings every time a new file is created. Android installs that key in the
session keyring every process inherits.

systemd's system manager joins a brand new session keyring while it starts so
that services get a clean one. The new keyring does not contain Android's key,
so every service loses the ability to create files and fails with ENOKEY.
Reading existing files keeps working, which is why the damage looks selective.
These three units run only after a package change, so the failure appears right
after installing or reconfiguring something. Since systemd-update-done can never
record completion, the same three units fail again on every later start and the
manager stays degraded permanently. pam_keyinit does the same thing to SSH
logins.

DawnShell measures this inside the rootfs immediately before executing systemd
and, when the filesystem is affected, installs a seccomp filter that reports
ENOSYS for KEYCTL_JOIN_SESSION_KEYRING. systemd keeps the inherited keyring,
logs the refusal at debug level, and continues; pam_keyinit is configured as
optional. The launcher records:

    BFU_DEBIAN_STAGE session_keyring_join_blocked
    reason=fscrypt_key_lost_in_new_session_keyring

Confirm the behaviour yourself from a shell inside Debian. The second write
fails only on an affected filesystem:

```sh
perl -e '
  open(my $a, ">", "/etc/dawnshell-key-a") or die "before: $!";
  close($a); unlink "/etc/dawnshell-key-a";
  syscall(219, 1, 0, 0, 0, 0);            # keyctl(KEYCTL_JOIN_SESSION_KEYRING)
  open(my $b, ">", "/etc/dawnshell-key-b") or die "after: $!";
  close($b); unlink "/etc/dawnshell-key-b";
  print "both writes succeeded\n";
'
```

Override the automatic decision only for diagnosis:

```sh
DAWNSHELL_SESSION_KEYRING_GUARD=off    # never install the filter
DAWNSHELL_SESSION_KEYRING_GUARD=force  # install without measuring
```

## apt network permission errors on LineageOS

Some LineageOS-derived kernels retain Android's paranoid-network permission
model: a process must belong to Android GID `3003` (`AID_INET`) to create
network sockets. Debian's unprivileged package downloader, `_apt`, may not have
that group. The phone can therefore be online while `apt` fails during
**Configure Debian 13 systemd + SSH**.

Current DawnShell first bind-mounts `/dev` in its private configuration mount
namespace, assigns GID 3003 to `_apt`, runs `dpkg --configure -a`, and only then
starts `apt`. Update the app and retry **Configure Debian 13 systemd + SSH**
first. The manual steps below are for repairing a rootfs left incomplete by an
older build.

Use this workaround only when root commands inside Debian have network access
but `_apt` reports `Permission denied`, `Operation not permitted`, or a socket
permission error. A missing default route or broken DNS needs a different fix.

Connect to Debian, become root, and inspect the existing account and group:

```sh
su root
id _apt
getent passwd _apt
getent group 3003 || true
```

If SSH configuration has not completed, unlock Android and enter the Debian
rootfs through ADB instead:

```sh
adb shell
su
/data/user_de/0/me.aroxu.dawnshell/files/bfu/bin/busybox \
  chroot /data/local/debian /bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Approve Magisk on the phone if prompted. `0` is Android's primary-user number;
for a secondary-user installation, replace it with the result of
`adb shell am get-current-user`. Run `exit` twice when finished to leave the
Debian root shell and then the ADB shell.

Run the following block from the **DawnShell Debian root shell**, not from the
Android shell. It creates `aid_inet` only when GID 3003 is unused and otherwise
reuses the existing group name.

```sh
if ! /usr/bin/getent group 3003 >/dev/null; then
    /usr/sbin/groupadd --gid 3003 aid_inet
fi

INET_GROUP="$(/usr/bin/getent group 3003 | /usr/bin/cut -d: -f1)"
test -n "$INET_GROUP" || {
    echo "ERROR: GID 3003 group was not found."
    exit 1
}

/usr/sbin/usermod --append --groups "$INET_GROUP" _apt
/usr/sbin/usermod --gid "$INET_GROUP" _apt
/usr/bin/id _apt
```

The final `id` output should contain GID 3003. Do not run `apt` or `dpkg` from
this raw ADB chroot: Android `/dev` has not been bind-mounted, so package
scripts will fail with `/dev/null: Permission denied`. Run `exit` twice, return
to the app, and run **Configure Debian 13 systemd + SSH** again. The app repairs
interrupted package configuration with the required private mounts. The group
change is stored in the Debian rootfs and survives reboot. `apt-get update` is
safe as a separate check only from a normally running DawnShell Debian reached
through SSH.

If `_apt` does not exist, diagnose the incomplete rootfs instead of creating
the account manually. If `groupadd` says GID 3003 already exists, reuse the
name shown by `getent group 3003`. If the result remains `Network is
unreachable`, collect `ip -brief address`, `ip route`, `/etc/resolv.conf`, and
the first failure in the app's **System configuration** log.

This grants network access to `_apt`; it does not enable SSH passwords or grant
root privileges. Current DawnShell reuses any existing GID 3003 group instead
of creating a duplicate.

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
the enabled host-IPC compatibility wrapper, then tap the global **Apply**
button.

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
/usr/local/libexec/dawnshell-codec-ffmpeg.pl plan-ffmpeg \
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
