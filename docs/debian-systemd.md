# Debian systemd and SSH

[한국어](debian-systemd.ko.md) · [Documentation](README.md) · [Glossary](glossary.md)

DawnShell runs systemd as PID 1 inside a private Debian PID namespace and keeps
that instance alive across the first Android unlock.

## Configuration

**Configure Debian 13 systemd + SSH** validates the rootfs, installs and configures
systemd, D-Bus, and OpenSSH, creates the `debian` account, installs the current
public key, disables SSH passwords and direct root login, enables a boot-proof
service, and verifies final ownership and permissions. Configuration starts only
while Android is unlocked.

## Runtime environment

Private mount, PID, UTS, and cgroup namespaces provide Debian-specific views.
The Android network namespace remains shared. The launcher mounts `/proc`,
`/sys`, `/dev`, `/dev/pts`, and `/run` without remounting host `/data`.

The cgroup policy probes delegated v2 plus device BPF first and falls back to
isolated v1 `devices` and `name=systemd` views after complete cleanup.

## Host-PID compatibility fallback

The full mode requires the kernel to create private PID and cgroup namespaces.
If `/proc/self/ns/pid` is absent, `CONFIG_PID_NS` is commonly disabled and
systemd cannot become Debian PID 1. Changing the cgroup backend cannot add that
kernel feature.

**Allow host-PID compatibility fallback** is a separate, default-off setting.
When enabled, DawnShell still tries the full runtime first. It switches modes
only when the required PID/cgroup namespace setup is unavailable, records
`mode=compat`, and starts `/usr/sbin/sshd -D` directly in the private Debian
mount and UTS namespaces. The SSH listener does not depend on an address already
being assigned, so late Wi-Fi or USB Ethernet is supported.

| Capability | Full mode | Host-PID fallback |
| --- | --- | --- |
| OpenSSH on TCP 22 | `ssh.service` | Direct `sshd -D` |
| Mount and hostname view | Private | Private |
| Process table | Private PID namespace | Shared with Android |
| systemd PID 1 and D-Bus | Available | Unavailable |
| Delegated cgroups and Docker | Available when the selected backend passes | Unavailable |
| Other enabled systemd services | Started normally | Not started |

This is an emergency SSH compatibility mode, not a reduced-isolation systemd
mode. Debian processes can see Android's host PID table. Use it only with a
trusted rootfs when rebuilding the kernel is not practical. Saving a change to
this setting restarts a running Debian instance once so the selected policy can
take effect.

## Network and SSH

Debian directly sees Android Wi-Fi, mobile, USB Ethernet, and VPN interfaces.
OpenSSH listens on wildcard TCP 22 even before an address is assigned.

```text
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
```

Only the public key enters Debian; the client private key remains in app CE.

## Lifecycle

In full mode, Stop requests a graceful systemd shutdown and then cleans
remaining children, mounts, and delegated cgroups. In compatibility mode it
terminates the tracked direct OpenSSH master and releases the private mount/UTS
runtime; there is no systemd service shutdown. Restart completes the applicable
cleanup before selecting a mode again. `USER_UNLOCKED` records state but never
stops Debian.

Status checks the supervisor, process identity, TCP 22, mounts, and namespace
identity in both modes. Full mode additionally checks PID 1, D-Bus, the default
target, `ssh.service`, and delegated cgroups. Compatibility health output is
explicitly labeled `mode=compat` and `compat_ready=true`.

## Android reboot bridge

In full mode, `systemctl reboot` remains inside the Debian isolation boundary.
To reboot the whole Android device from a Debian root shell, use:

```sh
reboot --check
reboot now
```

This managed reboot bridge requires full systemd mode and is unavailable in the
SSH-only compatibility fallback.
