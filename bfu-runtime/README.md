# BFU runtime

The active BFU runtime is Debian 13 rather than a standalone Dropbear tree.
`scripts/build-bootstrap-runtime.sh` builds the complete Android bootstrap set
from the pinned sources in this directory for `armeabi-v7a`, `arm64-v8a`, and
`x86_64`: a minimal BusyBox toolbox, Debian `pkgdetails`, GnuPG `gpgv`, and the
namespace/chroot launcher. The matching Debian architectures are `armhf`,
`arm64`, and `amd64`.

This directory tracks cross-repository runtime decisions. Runtime keys, authorized
keys, pids, and logs belong only in DawnShell Device Protected Storage or the
separately reviewed Debian rootfs on the device and must never be committed.
The embedded helper now owns probe/start/restart/status/health/stop plus a
restricted shutdown-isolation test; it never accepts an arbitrary shell command.
