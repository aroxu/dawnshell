# Security model

## Invariants

1. Termux CE storage is never accessed while `UserManager.isUserUnlocked()` is
   false.
2. BFU data is created only from a Device Protected Context owned by Termux:Boot.
3. No CE-to-DE automatic synchronization exists.
4. BFU authentication is public-key-only. Password and empty-password
   authentication are compile-time disabled in the final SSH binary.
5. DE must not contain private SSH keys, Termux user keys, API tokens, Tailscale
   auth keys, password databases, cloud credentials, or personal secrets.
6. Root is optional. Failure or absence of pre-authorized `su` cannot prevent the
   unprivileged BFU service from starting.

## DE exposure

Device-encrypted storage is protected by verified-boot/device keys, not the user's
PIN-derived CE key. Physical/offline and privileged compromise assumptions are
therefore weaker than for normal Termux. `authorized_keys`, a generated host
private key, pid files, and operational logs are acceptable only after the owner
accepts that boundary. A dedicated BFU client keypair limits the effect of future
key removal and avoids reusing normal administrative trust.

Host private keys necessarily need to be readable during BFU. They must be
generated specifically for BFU, mode 0600, never copied from normal Termux, never
logged, and clearly deleted/recreated when BFU is reset.

## SSH restrictions

The Dropbear milestone must enforce all of the following in code/build options, not
just advisory configuration:

- public-key authentication enabled;
- password, empty-password, PAM, shadow, and keyboard-interactive disabled;
- one unprivileged Android app UID;
- `/system/bin/sh` or an audited bundled shell only;
- `HOME=<DE>/bfu/home`, `TMPDIR=<DE>/bfu/tmp`;
- `PATH=<runtime>/bin:/system/bin:/system/xbin`;
- no agent forwarding, X11 forwarding, TCP forwarding, SFTP, SCP, or client tools
  unless each is deliberately reintroduced and reviewed;
- no command or key material in logcat.

The emergency login banner should state that the device has not been unlocked
since boot and show only non-sensitive diagnostics.

## Signing boundary

The Android shared UID makes signing part of the security architecture. F-Droid,
GitHub debug, and a custom key are different trust domains. Mixing them is expected
to fail with shared-user/signature errors. The correct deployment set is custom
Termux plus custom Termux:Boot (and every required plugin), all signed by one
private key.

The upstream `testkey_untrusted.jks` files in the pinned Termux and Termux:Boot
trees have the same SHA-256 file hash
`A2BA19F2417DE94DD3BDFB6CEECE070CDC5F9B492AF09CD5900058E860B18C7D`.
That is useful for local debug interoperability only; the password is public in
Gradle files and the key is unsuitable for production.

## Logging

Use tag `TermuxBFU`. Allowed messages include lifecycle action, DE root, runtime
verification, child pid/status, and sanitized exit errors. Never log key contents,
environment dumps, full command lines containing credentials, or SSH packet data.

