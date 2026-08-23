# Dropbear research note

[한국어](README.ko.md)

Dropbear 2026.94 was evaluated as an early minimal SSH-server candidate. The
current product uses OpenSSH inside the Debian rootfs, so this directory retains
source-research notes only.

Candidate acceptance criteria were an `arm64-v8a` PIE build, minimal dynamic
runtime dependencies, no fixed Android user or app-data path, and a pinned source
archive with SHA-256.

See the [glossary](../../docs/glossary.md) for ABI and related terms.
