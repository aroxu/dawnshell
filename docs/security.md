# DawnShell security model

[한국어](security.ko.md) · [Glossary](glossary.md)

DawnShell starts Debian and a network service with root privileges before PIN
entry. Its security rules are therefore stricter than those of an ordinary app.

## Principles

1. Never bypass Android Credential Encrypted (CE) storage.
2. Keep only BFU-essential, non-secret data in Device Encrypted (DE) storage.
3. Never store passwords, API tokens, reusable auth keys, or SSH private keys in DE.
4. Permit SSH public-key authentication only.
5. Limit root operations to fixed actions and fixed paths.
6. Never describe the Debian root environment as a fully isolated virtual machine.

See [Google's Direct Boot storage guidance](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted)
and the [AOSP FBE guide](https://source.android.com/docs/security/features/encryption/file-based).

## Threat model

The design considers unauthenticated network clients, other Android apps, stale
PID state, a modified rootfs, host-wide Docker or VPN changes, and secret leakage
through logs or the clipboard. A compromised kernel, ROM, or root manager remains
outside what an app can fully defend against.

## Android isolation

DawnShell has a dedicated UID and keeps internal components unexported. Android's
UID and SELinux isolation is described in the
[AOSP app sandbox guide](https://source.android.com/docs/security/app-sandbox).

## Storage

DE contains boot settings, public keys, non-secret logs, markers, and verified
runtime files. CE contains the generated SSH client private key. The boot gate
uses a sentinel and receipt to prove that app CE is inaccessible before unlock,
and checks [`UserManager.isUserUnlocked()`](https://developer.android.com/reference/android/os/UserManager#isUserUnlocked()).

If a modified ROM exposes CE during BFU, the default policy blocks startup. The
explicit override accepts that risk; it does not restore encryption.

## Root helpers

Helpers accept reviewed operation IDs, validate fixed rootfs targets, reject
unsafe values, never remount host `/data`, and verify UID, executable, and
namespace identity before stopping a supervisor or deleting data.

## SSH and passwords

The default policy is public-key authentication for `debian`, with password
authentication, empty passwords, and direct root login disabled. Local passwords
are passed to `chpasswd` through standard input and are not persisted in app
preferences, DE storage, logs, or command-line arguments.

Private-key export requires explicit user action. The local-shell import command
contains the complete private key, so file export is safer even though the app
attempts to clear the clipboard after 120 seconds.

## Network and Docker

Debian shares Android's network namespace. Root network changes can therefore
affect the whole device. Docker defaults to host-network-only mode with bridge,
iptables, forwarding, and masquerading disabled. Bridge mode should be used only
with a separate recovery path.

## Signing and releases

Verify Release checksums and use a private production signing key. Android update
identity is explained in [Google's app-signing guide](https://developer.android.com/studio/publish/app-signing).

## Operational recommendations

- Use a dedicated BFU SSH key.
- Keep reusable credentials out of the BFU rootfs.
- Grant permanent root only to the expected DawnShell package.
- Back up data and keys before destructive operations.
- Prepare local recovery before Docker bridge or high-risk root changes.
- Rotate the SSH key and reconfigure SSH after suspected compromise.
