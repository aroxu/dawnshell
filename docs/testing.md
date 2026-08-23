# DawnShell testing

[한국어](testing.ko.md) · [Glossary](glossary.md)

This plan validates installation, BFU startup, SSH, unlock continuity, networking,
cleanup, and destructive boundaries on a physical Android device.

## Preparation

Install the APK, grant permanent Magisk root, complete Debian and SSH setup,
export the client key, and prepare a separate recovery path. ADB is optional; see
[Google's ADB guide](https://developer.android.com/tools/adb).

## Static and ready-state checks

App status must report a ready rootfs, systemd PID 1, active D-Bus and SSH, TCP 22
listening, and healthy cgroups. The manifest must contain Direct-Boot-aware
receiver and service components as required by
[Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot#request_access).

## CE isolation

During BFU, a normal result contains:

```text
BFU_APP_CE_ISOLATED
```

`BFU_APP_CE_CONTENT_ACCESSIBLE` means the ROM exposed app CE before unlock and
must block startup unless the explicit risk override is enabled. See
[Google's DE/CE guidance](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted).

## Cold boot and unlock

Reboot without unlocking, then connect from another device:

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
id
cat /proc/1/comm
systemctl is-active ssh.service
ip addr
uptime
```

Systemd must be PID 1 and SSH must be active. Unlock Android while keeping the
session open. The session and PID 1 must remain unchanged, no duplicate
supervisor may appear, and `USER_UNLOCKED` must be recorded.

## Network behavior

Verify that SSH remains listening before Android assigns an address and becomes
reachable without a Debian restart when Wi-Fi, mobile data, or USB Ethernet comes
up. Test interface changes and any intended VPN or Tailscale path.

## Host USB policy

With USB passthrough off, restart Debian and verify that raw usbfs access is
absent and the lifecycle log records `policy=off` with major 189 denied. Select
direct mode, restart Debian, connect a known USB host device, and verify that its
`/dev/bus/usb/BBB/DDD` node appears while its Android driver remains bound.
Disconnect and reconnect it without restarting Debian.

For exclusive mode, choose a disposable test device, enter its exact `VID:PID`,
and keep ADB or physical recovery independent of that device. Verify the log
records `action=unbind`, libusb can claim it, unrelated devices stay bound, and
a normal Debian stop records `action=restore` and restores the driver. Repeat a
hot-plug cycle. Test USB storage only with one side mounted at a time.

## Five-cycle regression

Repeat reboot, locked SSH, PID 1 checks, first unlock, and continuity checks five
times. The harness is:

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/dawnshell-ed25519 \
./scripts/test-final-bfu.sh
```

Use `BFU_EXPECT_CE_READABLE_OVERRIDE=1` only on a ROM whose unsafe CE exposure has
already been confirmed and explicitly accepted.

## Lifecycle and cleanup

Stop must terminate SSH, systemd, and child processes and remove delegated mounts
and cgroups without disrupting Android networking. Start and restart must each
produce exactly one new systemd PID 1.

`reboot --check` must validate the Android reboot bridge, `reboot now` must reboot
the full device, and `systemctl reboot` must remain inside the Debian isolation
boundary.

## Pass criteria

- SSH works before PIN entry.
- App CE remains unavailable during BFU unless a documented override is active.
- The same Debian and SSH instance survives first unlock.
- Five cycles produce no duplicate processes or accumulated mounts.
- Delayed networking does not kill the listener.
- Stop and removal clean only verified targets.
