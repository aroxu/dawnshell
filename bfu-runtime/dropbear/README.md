# Dropbear research note

[한국어](README.ko.md) · [Documentation](../../docs/README.md)

Dropbear 2026.94 was evaluated as an early minimal SSH-server candidate. The
current product uses OpenSSH inside the Debian rootfs, so this directory retains
source-research notes only.

> This is not the APK's current BFU SSH path. Building or copying Dropbear does
> not change DawnShell's systemd/OpenSSH configuration.

Candidate acceptance criteria were an `arm64-v8a` PIE build, minimal dynamic
runtime dependencies, no fixed Android user or app-data path, and a pinned source
archive with SHA-256.

See the [glossary](../../docs/glossary.md) for ABI and related terms.
