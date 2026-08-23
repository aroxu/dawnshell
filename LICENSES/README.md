# DawnShell license bundle

DawnShell application source is licensed under MIT. The APK is an aggregate
that also carries separately executed native command-line programs, public
Debian archive keys, and Android libraries under their respective licenses.

Every file in this directory is copied into the APK under
`assets/open_source_licenses/`. The in-app **Open-source licenses** screen
renders the same bundle. Do not remove these files from binary distributions.

## Native bootstrap components

| Component | Version | License documents |
| --- | --- | --- |
| DawnShell Android/C code | repository version | `DawnShell-MIT.txt` |
| BusyBox | 1.38.0 | `GPL-2.0-only.txt` |
| Debian base-installer `pkgdetails` | 1.226 | `GPL-2.0-only.txt`, `base-installer-1.226-copyright.txt` |
| GnuPG `gpgv` | 2.4.9 | `GPL-3.0-or-later.txt`, `GnuPG-2.4.9-additional-notices.txt` |
| libgpg-error, libgcrypt, libassuan, npth | pinned in `SOURCES.lock` | `LGPL-2.1-or-later.txt` and component source notices |
| libksba | 1.6.8 | `LGPL-3.0-or-later.txt`, `GPL-2.0-only.txt`, `GPL-3.0-or-later.txt` |
| libgcrypt additional code | 1.12.1 | `Libgcrypt-1.12.1-additional-notices.txt` |
| debootstrap | 1.0.141 | `Expat.txt` |
| Debian archive keyring | 2025.1 | `GPL-2.0-or-later.txt`, `debian-archive-keyring-2025.1-copyright.txt` |

The complete, pinned corresponding source archives, Debian source descriptor,
Android-specific patches, configuration and build scripts are committed under
`bfu-runtime/` and `scripts/`. See `bfu-runtime/sources/SOURCES.lock`.

## Android libraries

See `ANDROID_DEPENDENCIES.md`. Apache-licensed dependencies use
`Apache-2.0.txt`; EdDSA-Java uses `CC0-1.0.txt`.

## Release rule

Every distributed APK must be accompanied by the corresponding-source archive
created by `scripts/package-release.sh`, or by equally clear and durable access
to that exact source revision. Release notes must identify the commit used to
build the APK.
