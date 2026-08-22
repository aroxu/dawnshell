# Termux BFU

Direct Boot proof of concept for starting a minimal Termux:Boot-owned environment
before the first user unlock, then handing off to normal Termux after CE storage
becomes available.

The project does not unlock, bind-mount over, copy, or otherwise bypass Termux CE
storage. BFU state belongs only in the Device Protected Storage returned by
`createDeviceProtectedStorageContext()`.

## Current status

The first proof of concept is implemented on the `bfu/direct-boot-poc` branch in
`termux-boot`:

- receives and logs `LOCKED_BOOT_COMPLETED` with tag `TermuxBFU`;
- starts a Direct-Boot-aware foreground service when BFU mode is enabled;
- provisions `files/bfu/{bin,etc,home,run,scripts,tmp}` in DE storage;
- directly executes the DE file `files/bfu/scripts/test.sh`;
- dynamically receives `USER_UNLOCKED` and hands off to the unchanged normal
  Termux boot-script scheduling path;
- also handles `BOOT_COMPLETED` as an AFU fallback and suppresses the unlock/boot
  race for 60 seconds;
- stores BFU settings and public authorized keys in Device Protected
  SharedPreferences.

An SSH daemon is not included yet. The current notification deliberately says
"planned SSH port" and the code never logs `SSH daemon started`.

## Upstream snapshots

| Repository | Branch | Commit |
| --- | --- | --- |
| `termux/termux-app` | `master` | `3df69d1da197dd9bd71a3bafd902dffd720576b4` |
| `termux/termux-boot` | `master` | `a8493bd6ba016bc370af34aa65fcbe065cc00ced` |
| `termux/termux-packages` | `master` | `84d74e940acd959cb5ebfdb38a012477f05f531a` |

Snapshots were fetched on 2026-08-22.

## Build prerequisites

- JDK 17
- Android SDK Platform 34 and Build Tools 34.0.0 for Termux:Boot
- ADB for device tests
- one signing key shared by Termux and every installed Termux plugin

Both upstream projects currently target SDK 28. Do not raise that value as part
of this proof of concept; API 29 applies the app-data `execve()` W^X restriction.

## Signing and migration warning

`termux-app` and `termux-boot` both declare `android:sharedUserId="com.termux"`.
Android therefore requires matching signing certificates. The checked-in upstream
debug keystores are byte-identical, but they are public, explicitly untrusted test
keys and must never be used as a private production identity.

Before replacing an F-Droid installation:

1. In existing Termux, save `$HOME`, `$PREFIX/etc`, `pkg list-installed`, SSH keys,
   and app-specific configuration to storage outside the app sandbox.
2. Verify that the backup can be read from another machine or app.
3. Uninstall Termux and every plugin signed by the old source.
4. Build and sign Termux, Termux:Boot, and required plugins with one private custom
   key, then install all of them from that set.
5. Restore normal Termux CE data only after launching and bootstrapping custom
   Termux. Never restore CE credentials into the BFU DE tree.

See [architecture](docs/architecture.md), [security](docs/security.md),
[testing](docs/testing.md), and [progress](docs/progress.md).

