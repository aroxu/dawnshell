# DawnShell user guide

[한국어](user-guide.ko.md)

[Project home](../README.md) · [Installation guide](installation.md) ·
[Troubleshooting](#troubleshooting)

This guide covers normal operation after DawnShell has been installed and its
initial setup completed. If the rootfs and systemd/SSH are not configured yet,
follow the [installation guide](installation.md) first.

## Core behavior

- Debian systemd and SSH start from `LOCKED_BOOT_COMPLETED` after a cold boot.
- The same Debian instance remains alive before and after Android's first unlock.
- Debian shares Android's NICs and network namespace.
- App settings, logs, and public keys live in DE; the client private key lives in
  app CE; the complete Debian rootfs lives at `/data/local/debian`.
- SSH accepts public-key authentication for user `debian` on TCP 22 by default.
- A Debian root shell has device-level Android root authority. Do not treat this
  environment as a security-isolated container.

## Dashboard sections

### 1 · Direct Boot

**Enable Direct Boot Debian bootstrap** controls automatic startup on the next
cold boot. After changing a switch, always tap **Save BFU settings and provision
runtime**. The dashboard displays a warning while changes remain unapplied.

**Request / verify Magisk root permission** verifies during AFU that the current
app UID can become root. Before a cold boot, separately confirm that Magisk kept
the permanent authorization policy.

**Refresh BFU probe results** only reads stored locked-boot evidence. Pressing it
after unlock does not rerun a BFU probe or turn an AFU result into BFU success.

The CE-readable override is a dangerous diagnostic option. Leave it off on a
correctly configured FBE device. It does not repair encryption; it only accepts
the risk and removes the startup block when the ROM already exposes CE before
first unlock.

### 2 · Debian setup

**Install Debian 13 Trixie rootfs** performs an initial installation or validates
an existing recognized installation. It does not overwrite `/data/local/debian`
or perform an in-place release upgrade.

**Configure Debian 13 systemd + SSH** installs and configures systemd, D-Bus,
OpenSSH, user `debian`, the current app public key, and the boot-proof service.
Run it again after rotating the SSH client key or restoring a rootfs.

Both operations can be started only during AFU while Android is unlocked. Watch
the Debian installation and system configuration logs while they run.

### 3 · Server controls

- **Start** validates the rootfs and ready marker, then starts a new Debian
  systemd as namespace PID 1.
- **Restart** gracefully exits the verified instance, then starts a new one.
- **Status** checks supervisor identity, namespaces, systemd, D-Bus, the target,
  SSH, TCP 22, and cgroup health.
- **Stop** asks systemd to clean up units through its container `exit` path and
  stops SSH.

Android unlock never invokes Stop automatically. After a manual stop, tap Start
when you need Debian again, or wait for the next enabled cold boot.

### 4 · SSH access

**Export SSH private-key file** is the recommended route for an external computer.
The exported file is an unencrypted credential; store it privately and restrict
it to mode 0600.

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

**Copy Termux private-key import command** is a one-time convenience for your own
Termux session on the same phone. The entire command contains the private key.
Never paste it into another app, a messenger, or a shared shell-history view.
**Copy SSH connect command** copies a command for `debian@127.0.0.1:22`.

**Generate a new random SSH client key** permanently replaces the client identity.
Rotate it in this order:

1. Back up the old private key if it is still needed.
2. Generate the new key.
3. Run **Configure Debian 13 systemd + SSH** again.
4. Export the new private key to each client.
5. Verify the new login, then retire old exports.

If reinstalling the rootfs changes the SSH host key, confirm that a reinstall
really occurred before removing only that known-hosts entry:

```sh
ssh-keygen -R "[PHONE_IP]:22"
```

### Accounts

You can set local passwords of 8–128 characters for `root` and `debian`. They are
sent only through `chpasswd` stdin and are not stored in Android settings, DE, or
logs. SSH continues to deny password authentication and root login.

After connecting over SSH as `debian`, become root with:

```sh
su root
```

Enter the Debian root password configured in DawnShell. Run `exit` to leave the
root shell. This root account has real device-level authority in the shared
Android network and IPC namespaces, so run only trusted commands.

To intentionally reboot the complete Android device from that root shell:

```sh
reboot --check
reboot now
```

`reboot --check` validates the host bridge without rebooting. `reboot now`
immediately reboots Android. In contrast, `systemctl reboot` is a Debian namespace
isolation path and should not be used when a whole-device reboot is intended.

### Kernel and Docker compatibility

Keep the cgroup policy at **Automatic: v2, then v1 fallback**. Force-v2 can prevent
Debian from booting when device BPF or delegation is unavailable; force-v1 skips
the modern path. A cgroup setting takes effect on the next Debian start or restart.

With the recommended Docker policy, **Safe host network only**, run containers as:

```sh
docker run --network host ...
```

Bridge modes can change Android-global firewall, NAT, forwarding, and routes,
disconnecting Wi-Fi, mobile data, USB Ethernet, VPN/Tailscale, or the current SSH
session. Do not force a bridge backend over your only remote recovery connection.
Selecting a radio button does not apply a network change; mutation occurs only
after tapping **Apply Docker network policy**. DawnShell then stops Debian, probes
the backend, writes policy, and restores the prior running state.

### Logs

Open **Logs** from the top app bar and choose a stream:

- App operations: button requests, validation results, and errors
- Debian installation: debootstrap and rootfs publication
- System configuration: APT, systemd, OpenSSH, and account provisioning
- Compatibility policy: cgroup and Docker backend probes
- Server lifecycle: start, stop, restart, status, and health
- Direct Boot diagnostics: boot marker and BFU root, CE, rootfs, and chroot probes

Each reader refreshes once per second and supports scrolling, long-press selection,
and copy-all. Automatic follow pauses while text is selected or while you read
older lines above the bottom. When reporting an error, copy the relevant stream
but never add a private key or password.

## Networking

sshd listens on wildcard TCP 22 even before an address exists. If Android later
adds a Wi-Fi, mobile, or USB Ethernet address, clients can connect without
restarting Debian.

From a computer on the same network:

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

From Termux on the same phone:

```sh
ssh -i "$HOME/.ssh/dawnshell-ed25519" -p 22 debian@127.0.0.1
```

Kernel-mode Tailscale shares `tailscale0`, routes, and netfilter state with
Android. Prefer interactive enrollment and never store a reusable auth key in the
BFU rootfs. Treat an enrolled `tailscaled.state` as a device credential available
before PIN entry.

## Updates and backups

Download official updates from [GitHub Releases](https://github.com/aroxu/dawnshell/releases)
and verify `SHA256SUMS`. Install an APK signed with the same release key over the
existing app. After updating, unlock Android, tap **Save BFU settings and provision
runtime**, and verify status, restart behavior, and a planned cold boot.

Recommended backups:

- the DawnShell SSH client private key exported from the app;
- required Debian `/etc`, user data, and service configuration;
- the installed package list and application-specific data.

App settings and the rootfs are not automatically synchronized in either
direction. Uninstalling the APK removes app CE/DE and the generated client key but
does not remove `/data/local/debian`. Conversely, deleting the rootfs from the
Danger zone leaves app settings and logs intact.

## Safe removal

To remove Debian and the app completely:

1. Back up required data and the client key.
2. Unlock Android, tap **Stop**, and use Status to confirm systemd is absent.
3. Open **Danger zone → Permanently delete Debian rootfs**.
4. Accept both confirmations and type the literal word `DELETE`.
5. Require `DEBIAN_ROOTFS_REMOVE_SUCCEEDED` in the operation log.
6. Uninstall DawnShell from Android settings.

The destructive target is exactly `/data/local/debian`. If staging or failed
siblings remain, inspect their logs and origin before handling them separately.

## Troubleshooting

### Debian does not start after a cold boot

- Confirm that you tapped **Save BFU settings and provision runtime** after
  enabling Direct Boot.
- Confirm permanent DawnShell authorization in Magisk.
- After unlocking, inspect Direct Boot diagnostics for a new
  `LOCKED_BOOT_COMPLETED`, then BFU root, CE isolation, rootfs, and chroot results
  in that order.
- Exempt the app from vendor battery or autostart restrictions.

### `root=false`, timeout, or permission denied

Unlock Android, request root again, and select permanent authorization in Magisk.
BFU cannot display an approval UI, so a one-time grant cannot solve cold-boot
authorization. Do not approve if an unexpected package appears in the same-UID
package list.

### Debian installation fails

Copy the final `ERROR:` and `DEBOOTSTRAP_LOG_TAIL` from the Debian installation
log. Never bypass a checksum or Release-signature error. Interrupted staging is
preserved automatically; do not blindly delete `/data/local/debian.installing`
or `.failed.*` before collecting diagnostics.

### The systemd + SSH configuration request fails

Confirm that Android is unlocked, Direct Boot settings were saved, rootfs status
is `SUCCEEDED`, and Magisk root still works. Copy the first failed stage from the
system configuration log, provision the runtime again, and retry.

### `ssh: connect ... port 22: Connection refused`

1. Check **Status** and the server lifecycle log.
2. Confirm that systemd/SSH configuration completed.
3. In Debian, check `systemctl is-active ssh.service` and `ss -ltn`.
4. Check whether another process owns TCP 22.
5. For a remote connection, confirm that Android received an address during BFU.

Plain `ssh user@host` uses port 22, which is also DawnShell's default. `-p 22` is
optional, but the key and user `debian` must still be correct.

### `network is unreachable`

Separate an sshd problem from an uplink problem. If localhost SSH at `127.0.0.1`
works but a remote client does not, inspect Android interfaces, addresses, and
routes. If the ROM does not restore Wi-Fi during BFU, DawnShell cannot unlock or
open that network credential on its behalf.

### CE isolation blocks startup

On a correct FBE device, blocking is the expected result when CE content is
readable. Investigate the ROM and FBE configuration first. Enable the CE-readable
override only if you accept that the ROM already exposes CE before unlock. The
override does not restore the lost security property.

### Network access breaks after applying Docker policy

Use an independent recovery path such as a local console or ADB if available.
Open DawnShell, select **Safe host network only**, and apply the policy. Copy the
compatibility log. Docker bridge rules affect Android globally because the
network namespace is shared.

### An update APK will not install

The usual cause is a certificate mismatch between a debug/custom APK and an
official release. Back up the current client key and data before taking action.
Uninstalling the old app deletes app CE/DE, so do not do it without preparation.
If two official releases conflict, report the release assets, checksums, versions,
and certificate information.

## Related documents

- [Installation guide](installation.md)
- [Security model](security.md)
- [Architecture](architecture.md)
- [Complete test plan](testing.md)
- [Rootfs installation internals](rootfs-installation.md)
