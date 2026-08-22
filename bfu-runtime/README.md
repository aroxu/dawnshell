# BFU runtime

The active BFU runtime is now Debian 13 rather than a standalone Dropbear tree.
The first native runtime component is the ARM64 namespace/chroot probe under the
`termux-boot` source tree; its reproducible NDK build script and source are shipped
next to the APK asset so the fork remains self-contained.

This directory tracks cross-repository runtime decisions. Runtime keys, authorized
keys, pids, and logs belong only in Termux:Boot Device Protected Storage or the
separately reviewed Debian rootfs on the device and must never be committed.
The embedded helper now owns probe/start/restart/status/health/stop plus a
restricted shutdown-isolation test; it never accepts an arbitrary shell command.
