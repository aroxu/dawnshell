# DawnShell user manual

[한국어](user-guide.ko.md)

[Project home](../README.md) · [Installation guide](installation.md) ·
[Glossary](glossary.md) · [Troubleshooting](#troubleshooting)

This manual covers daily operation after installation. Follow the
[installation guide](installation.md) first if Debian and SSH are not configured.

## Core behavior

- BFU means Before First Unlock; AFU means After First Unlock.
- DawnShell starts Debian systemd and SSH during BFU.
- The same instance remains running after unlock.
- Debian shares the Android kernel and network and is not a fully isolated VM.

See the [glossary](glossary.md) for DE, CE, PID, rootfs, and other terms, or read
[Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot).

## Direct Boot controls

**Enable Direct Boot Debian bootstrap** controls automatic startup on the next
cold boot. After changing it, tap **Save and provision BFU runtime**.

**Request / verify Magisk root permission** checks current root access. Magisk
must grant permanent approval because BFU cannot display a prompt.

**Refresh BFU probe results** reads evidence from the last locked boot; it does
not rerun the probe while Android is unlocked.

Keep the BFU CE-readable override disabled on a normal FBE device. It accepts an
already unsafe ROM condition; it does not repair encryption.

## Debian setup and lifecycle

**Install Debian 13 Trixie rootfs** creates `/data/local/debian` without silently
overwriting a valid installation. **Configure Debian 13 systemd + SSH** prepares
systemd, D-Bus, OpenSSH, the `debian` account, the current public key, and boot
proof services. Both operations run only after Android is unlocked.

- **Start:** validate and start Debian systemd.
- **Restart:** gracefully stop and start a new instance.
- **Status:** check systemd, D-Bus, SSH, TCP 22, and cgroups.
- **Stop:** stop Debian services and SSH.

Unlocking Android never stops the running server.

## SSH access

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

## Accounts and root

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

## Kernel and Docker

Keep the recommended automatic cgroup v2-to-v1 fallback unless diagnosing a
specific kernel. Docker defaults to safe host-network-only mode:

```sh
docker run --network host ...
```

Bridge networking can change Android-wide firewall, NAT, forwarding, and routes.
It can disconnect Wi-Fi, mobile data, USB Ethernet, VPNs, Tailscale, and SSH.
Prepare a separate recovery path before enabling a forced bridge backend.

## Logs

The Logs screen provides app operations, Debian installation, system
configuration, compatibility, lifecycle, and Direct Boot diagnostics. Readers
refresh once per second and support scrolling, selection, and copying. Do not add
private keys or passwords when sharing a log.

## Networking

The SSH server listens on TCP 22 even before Android assigns an address. When
Android later brings up Wi-Fi, mobile data, or USB Ethernet, no Debian restart is
required.

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

Treat `tailscaled.state` as a device credential available before PIN entry. Do
not store reusable authentication keys in the BFU rootfs.

## Backup and removal

Back up the exported SSH client key, important Debian configuration and user
data, package lists, and service configuration.

To remove Debian completely, stop it, confirm systemd is absent, open the danger
zone, choose permanent rootfs removal, complete both confirmations, type
`DELETE`, and verify `DEBIAN_ROOTFS_REMOVE_SUCCEEDED`. Then uninstall DawnShell
from Android settings if desired.

## Troubleshooting

### No BFU startup

Save and provision settings, verify permanent Magisk approval, inspect the latest
`LOCKED_BOOT_COMPLETED` diagnostics after unlock, and exclude the app from vendor
battery and automatic-start restrictions.

### Root denied or timed out

Request root while unlocked and select permanent approval in Magisk. BFU cannot
display an interactive root prompt.

### Debian installation failed

Copy the final `ERROR:` and `DEBOOTSTRAP_LOG_TAIL` from the installation log. Do
not bypass signature or checksum failures, and preserve staging data for diagnosis.

### SSH connection refused

Check app status and lifecycle logs, verify systemd + SSH configuration, run
`systemctl is-active ssh.service` and `ss -ltn`, check for a TCP 22 conflict, and
confirm that Android has a BFU network address.

### Network unreachable

If localhost SSH works but remote SSH does not, inspect Android interfaces,
addresses, and routes. DawnShell cannot unlock Wi-Fi credentials that the ROM
keeps unavailable during BFU.

### Docker disconnected Android networking

Use a local screen or ADB recovery path to reapply safe host-network-only mode,
then collect the compatibility log.

## Related documents

- [Installation guide](installation.md)
- [Glossary](glossary.md)
- [Security model](security.md)
- [Architecture](architecture.md)
- [Testing](testing.md)
