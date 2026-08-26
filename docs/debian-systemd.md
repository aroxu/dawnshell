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

Stop requests a graceful systemd shutdown, then cleans remaining children,
mounts, and delegated cgroups. Restart completes that cleanup before starting a
new PID 1. `USER_UNLOCKED` records state but never stops Debian.

Status checks the supervisor, boot ID, PID 1, D-Bus, target, SSH service, TCP 22,
cgroups, mounts, and namespaces.

## Android reboot bridge

`systemctl reboot` remains inside the Debian isolation boundary. To reboot the
whole Android device from a Debian root shell, use:

```sh
reboot --check
reboot now
```
