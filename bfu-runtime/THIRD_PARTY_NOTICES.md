# Bundled third-party notices

[한국어](THIRD_PARTY_NOTICES.ko.md) · [Documentation](../docs/README.md) · [Build and release](../docs/building.md)

DawnShell application code is MIT licensed. The APK also aggregates separately
executed programs and public Debian keys under their upstream terms.

| Component | License |
| --- | --- |
| BusyBox 1.38.0 | GPL-2.0-only |
| Debian base-installer 1.226 `pkgdetails` | GPL-2.0-only |
| GnuPG 2.4.9 `gpgv` | GPL-3.0-or-later |
| libgpg-error, libgcrypt, libassuan, libksba, npth | Their upstream LGPL/GPL terms |
| debootstrap 1.0.141 | Expat/MIT-style |
| Debian archive keyring 2025.1 | Public key data; package GPL-2.0-or-later |
| AndroidX, Material Components, Kotlin, and related Android libraries | Their upstream terms, including Apache-2.0 |
| EdDSA-Java 0.3.0 | CC0-1.0 |

Full license texts and required notices are in `LICENSES/`. Pinned corresponding
source, versions, and SHA-256 values are under `bfu-runtime/sources/`; patches and
configuration are under `bfu-runtime/patches/` and `bfu-runtime/config/`.

GitHub Releases include corresponding-source and license bundles next to the APK.
The same material is selectable from the app's open-source licenses screen.
