# Bundled bootstrap runtime notices

DawnShell application code remains licensed under MIT. The APK also contains
separately built command-line programs and public Debian archive keys under
their own upstream licenses:

- BusyBox 1.38.0 (`dawnshell-toolbox`): GPL-2.0-only.
- Debian base-installer 1.226 `pkgdetails`: GPL-2.0-or-later.
- GnuPG 2.4.9 `gpgv`: GPL-3.0-or-later.
- libgpg-error, libgcrypt, libassuan, libksba, and npth are statically linked
  into `gpgv`; consult each vendored source archive for its exact license and
  notices.
- debootstrap 1.0.141: Expat/MIT-style license.
- Debian archive keyring 2025.1: public key data distributed by Debian; its
  packaging is GPL-2.0-or-later.

The pinned corresponding source archives and SHA-256 records are in
`bfu-runtime/sources/`. DawnShell's Android-specific BusyBox patch, the
cross-build-only libgpg-error deprecated-config-test exclusion, and the minimal
BusyBox configuration are in `bfu-runtime/patches/` and `bfu-runtime/config/`.
