# Security model

## Invariants

1. Termux CE storage is never accessed while `UserManager.isUserUnlocked()` is
   false.
2. BFU data is created only from a Device Protected Context owned by Termux:Boot.
3. No CE-to-DE automatic synchronization exists.
4. DE must not contain private SSH keys, Termux user keys, API tokens, Tailscale
   auth keys, password databases, cloud credentials, or personal secrets.
5. Root is required for the Debian launcher but is never assumed: each boot must
   prove `su -c id` returned `uid=0`, and failure cannot crash the BFU controller.
6. The Debian launcher must not create a network namespace or alter the host mount
   propagation/cgroup topology outside its private mount namespace.

## DE exposure

Device-encrypted storage is protected by verified-boot/device keys, not the user's
PIN-derived CE key. Physical/offline and privileged compromise assumptions are
therefore weaker than for normal Termux. DE contains only bootstrap/control files
and operational logs. Debian service credentials belong inside the separately
selected BFU-accessible rootfs and require their own threat review.

## Root and namespace restrictions

Magisk authorization must be granted to the Termux/Termux:Boot shared UID before
reboot. The BFU path must never wait indefinitely for an authorization UI; the
probe is bounded and records only command path, exit status, timeout state, root
verdict, and sanitized `id` output.

The root launcher must use exact, validated paths and make `/` recursively private
before bind mounts. It must not bind DE over CE, weaken FBE/SELinux, remount Android
cgroups globally, or treat a stale pid file as proof that Debian is running.
Shutdown/reboot requests inside the Debian PID namespace must be tested to ensure
they cannot unintentionally reboot the Android host.

The rootfs accessibility gate writes only a random-per-process marker named
`.termux-bfu-access-probe.<pid>` at the rootfs top level, reads it back, and removes
it through an EXIT/signal trap. It does not modify Debian configuration, users,
services, mounts, or CE storage.

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
