# Progress

## Standalone split — 2026-08-23

- [x] Create a root-level Android project with package `me.aroxu.dawnshell`,
  version `0.1.0`, and launcher name **DawnShell**.
- [x] Remove `sharedUserId`, `BootJobService`, `TermuxService`, normal
  `~/.termux/boot` dispatch, and signing-key coupling with Termux.
- [x] Move CE-isolation proof to the standalone app's own CE sentinel and retain
  app-owned DE settings, keys, runtime files, and logs.
- [x] Generate a random Ed25519 client identity in app CE, provision only its
  public half into DE/Debian, and add explicit file/Termux-command export paths.
- [x] Remove legacy compatibility and use DawnShell names for Android state,
  rootfs markers, systemd units, runtime controls, hostname, and SSH artifacts.
- [x] Preserve Debian 13 systemd/OpenSSH, local password controls, private-rootfs
  setuid, persistent-after-unlock behavior, and the existing `/data/local/debian`.
- [x] Negotiate cgroups by capability: try a delegated cgroup-v2 subtree plus a
  real cgroup-device BPF attach first, clean it completely on failure, then fall
  back to delegated devices-v1 and `name=systemd` children.
- [x] Make native health and the cold-boot SSH harness accept only a verified v2
  unified view or verified v1 devices view, and persist the resolved mode.
- [x] Build and lint successfully with JDK 17; verify target SDK 28,
  `LOCKED_BOOT_COMPLETED`, Direct-Boot-aware receiver/service, no manifest shared
  UID, and APK signature schemes v1/v2.
- [x] Validate devices-v1 delegation far enough for Docker/containerd to pass
  cgroup initialization on the physical target; the next observed failure was
  Docker's incompatible nftables firewall frontend.
- [ ] Validate the new network-backend negotiation and perform the five-cycle BFU
  session on the physical target.

Staged APK: `dist/dawnshell_0.1.0_debug.apk`

SHA-256: `D919C19D5D75CB94B6313405A1D78F90B42C13DC1695662CB8BFDD6E0E659FE1`

The entries below record the earlier BFU-enabled Termux:Boot PoC history.

## 2026-08-22

- [x] Clone current `master` of termux-app, termux-boot, and termux-packages.
- [x] Pin and record all three upstream HEAD commits.
- [x] Confirm target SDK 28 in Termux and Termux:Boot.
- [x] Confirm shared UID `com.termux` and identical upstream debug keystore files.
- [x] Trace BootReceiver -> JobScheduler -> BootJobService -> TermuxService.
- [x] Confirm Termux CE and prefix paths are hardcoded upstream.
- [x] Confirm `USER_UNLOCKED` requires a runtime receiver.
- [x] Add Direct-Boot-aware locked boot receiver and BFU foreground service.
- [x] Add Device Protected settings/provisioning UI.
- [x] Add DE layout and direct executable probe.
- [x] Preserve AFU scheduling and add unlock/boot duplicate suppression.
- [x] Persist every `LOCKED_BOOT_COMPLETED` receipt in the DE-only
  `files/bfu-boot.log` marker and validate a fresh line in the test script.
- [x] Verify Android command-line-tools archive SHA-256 against the official value.
- [x] Build and sign the Termux:Boot debug APK with portable JDK 17 / SDK 34.
- [x] Verify final APK manifest, target SDK 28, Direct Boot components, and signature.
- [x] Run Gradle lint (0 errors; 2 remaining upstream/design warnings) and unit-test task
  (no unit-test sources exist upstream).
- [x] Install Android Platform 36, Build Tools 35/36, and NDK 29.0.14206865.
- [x] Build Termux 0.118.0 `apt-android-7` split and universal debug APKs.
- [x] Select and stage the Note 8 `arm64-v8a` Termux APK with the BFU Boot APK.
- [x] Verify both APKs have target SDK 28, shared UID `com.termux`, and an identical
  signing-certificate digest.
- [x] Verify `LOCKED_BOOT_COMPLETED`, DE storage, foreground service, DE native
  execution, and `USER_UNLOCKED` handoff on the physical SM-N950N / Android 16.
- [x] Verify PID, mount, UTS, and cgroup namespace creation on kernel 4.4.302;
  retain Android IPC because this vendor kernel cannot safely create it.
- [x] Verify a `--mount-proc` PID-namespace helper becomes PID 1 with an isolated
  `/proc` process view.
- [x] Replace the BFU Dropbear milestone with the Debian/systemd boot target.
- [x] Add bounded BFU `su -c id` probing and DE-persistent root result logging.
- [x] Add an unlock-time UI reader for the last DE root result; it never reruns the
  probe or substitutes AFU output for BFU evidence.
- [x] Remove unlock-time BFU service shutdown; unlock now performs AFU handoff only.
- [x] Verify Debian gate 1 on-device: `/system/xbin/su`, `exit=0`, `uid=0(root)`,
  Magisk SELinux context, and locked state before/after the probe.
- [x] Add an AFU-only Magisk authorization/verification button with a shared-UID
  scope warning and a DE log that cannot be confused with BFU evidence.
- [x] Implement gated `/data/local/debian` directory, shell-mode, and temporary
  read/write probe with a DE-persistent result.
- [x] Confirm on-device gate-2 probe failure is exactly `stage=root_missing`, not
  a BFU root, DE, or SELinux regression.
- [x] Add an AFU-only upstream Debian rootfs installer with pinned artifacts,
  signature enforcement, private mounts, staging validation, and no overwrite.
- [x] Switch the fresh-install target to Debian 13 Trixie arm64 with release-native
  debootstrap/keyring pins and explicit suite/version validation.
- [x] Add a DE-persistent installer status/log and a one-second live tail in the
  Termux:Boot activity.
- [x] Present the live installer log as a selectable console and pause follow
  while text is selected or the operator reads older lines.
- [x] Add the split Termux `mount-utils` prerequisite and propagate the root
  helper's final sanitized `ERROR:` line into the visible installer status.
- [x] Avoid the vendor Android 16 forced-scrollbar crash in the selectable log
  console while retaining touch scrolling and text selection.
- [x] Diagnose the first physical-device Trixie bootstrap past required-package
  configuration: Android `mksh` retained debootstrap's target-only `PATH`
  assignment, so host helpers switched from Termux tools to toybox and looked
  for a nonexistent `https:__..._Packages` apt-list path.
- [x] Scope debootstrap target commands to a subshell so the AFU Termux host
  `PATH` survives every chroot call; add the internal debootstrap log tail to
  visible failure output.
- [x] Present root authorization, BFU probes, provision operations, Debian
  status, and Debian output as selectable console views with independent touch
  scrolling and outer-page handoff at console edges.
- [x] Persist a DE-only 48 KiB live tail for button/provision results without
  storing credentials.

## 2026-08-23

- [x] Complete the Debian 13 Trixie rootfs installation on the physical target.
- [x] Add a CE-independent ARM64 namespace/chroot probe with pinned native-asset
  SHA-256, strict rootfs validation, private mounts, and bounded execution.
- [x] Show the latest namespace/chroot result in the same selectable probe console
  UI and add an automated cold-boot evidence script.
- [x] Implement identity-backed native `start/status/stop` with a lifetime lock,
  graceful systemd manager exit, stale/orphan detection, and DE lifecycle checkpoints.
- [x] Add a private cgroup-v1 `name=systemd` subtree and process-local systemd 257
  legacy-force flags without creating a network namespace or exposing Android
  controller mounts.
- [x] Add validated DE public-key storage and an AFU-only Debian 13 systemd,
  D-Bus, and public-key-only OpenSSH configurator.
- [x] Start Debian automatically after locked-boot gates pass and keep it unchanged
  across `USER_UNLOCKED` while normal Termux:Boot handoff still runs.
- [x] Add selectable, independently scrollable live configuration/lifecycle logs
  and explicit start/status/graceful-stop maintenance controls.
- [x] Add an end-to-end BFU SSH test that compares Debian PID 1 identity before
  and after first unlock.
- [x] Add a fail-closed shared-UID BFU CE sentinel probe that distinguishes an
  enumerable empty mount stub from readable normal Termux CE contents.
- [x] Record PID/mount/UTS/cgroup/IPC/network namespace identities and require
  private requested namespaces plus unchanged Android IPC only.
- [x] Replace the private veth/NAT path with native shared-NIC networking and a
  delayed IPv4/IPv6 route-table watcher scoped to Tailscale's Linux bypass mark;
  support Wi-Fi/mobile/USB Ethernet changes and bounded rule cleanup.
- [x] Add a root-only fixed-token FIFO bridge for `reboot now` to intentionally
  reboot Android while preserving `systemctl reboot` isolation tests.
- [x] Add bounded native health checks for systemd PID 1, D-Bus, default target,
  an independent enabled-unit proof, `ssh.service`, and TCP 22, with locked-state
  evidence persisted in DE.
- [x] Require `multi-user.target` itself to be active instead of treating its
  configured default-target name as proof that the boot target was reached.
- [x] Add explicit restart control, a private rootfs bind mount, read-only `/sys`,
  and boot-ID-scoped normal Termux handoff deduplication.
- [x] Add restricted Debian poweroff/reboot/shutdown isolation tests and a
  configurable final BFU harness (five cycles by default) that records
  boot/process/RSS evidence and requires
  fresh same-cycle evidence for every locked-boot gate.
- [x] Prevent an AFU `BOOT_COMPLETED` service recreation from rerunning BFU probes
  and contaminating the locked-only evidence stream.
- [x] Make the final harness compare both installed APKs to the local staged pair,
  record their build-specific hashes, and reject a stale embedded or provisioned
  native helper before accepting any physical result.
- [x] Fix two AFU reconfiguration defects exposed on-device: validate Debian's
  real `/usr/bin/mawk` executable instead of the host-relative alternatives link,
  and create the private-tmpfs `/run/sshd` directory before `sshd -t`.
- [x] Preserve the reboot pstore and identify the first systemd start failure as
  a Samsung 4.4 kernel translation fault in
  `unshare -> copy_ipcs -> mq_init_ns -> mqueue_mount -> mount_ns`.
- [x] Remove every `unshare(CLONE_NEWIPC)` path, add a build-time regression
  rejection, and require the target topology to share Android IPC while keeping
  mount/PID/UTS/cgroup private and networking shared.
- [x] Mask the Android-inapplicable console getty, require systemd state
  `running`, and prove AFU systemd, D-Bus, proof unit, TCP 22, and public-key SSH
  on the physical target.
- [x] Replace the target's hanging halt-signal maintenance stop with systemd's
  container `exit` operation; verify 0.76-second stop, `wait_status=0`, and an
  unchanged Android boot ID on-device.
- [x] Add copyable Termux CE private-key import and localhost SSH commands;
  verify Debian UID 1000 login and zero private-key material in DE.
- [x] Add AFU-only local Debian password controls and private-rootfs-only setuid
  support for interactive `su root`, while keeping OpenSSH public-key-only.
- [x] Replace the legacy programmatic Termux-style screen with a Material 3
  dashboard while retaining every installer, lifecycle, key, account, and
  destructive action binding.
- [x] Restore the ROM-specific CE-readable override to the primary Direct Boot
  card and visibly flag unapplied switch changes.
- [x] Move operation, installation, configuration, lifecycle, and BFU diagnostic
  logs into a live index plus dedicated full-screen selectable/copyable readers.
- [x] Remove AndroidX automatic startup/profile components introduced by the UI
  stack so the locked-boot process remains receiver/service-only.
- [x] Add a private-mount-namespace devices-v1 hierarchy, delegate only its
  `dawnshell` child into Debian, require it in health, and add ordered teardown.
- [x] Replace kernel-version assumptions with cgroup capability negotiation:
  delegated v2 plus a real cgroup-device BPF attach probe first, then complete
  cleanup and the verified v1 devices/name=systemd fallback.
- [x] Add DE-backed auto/force-v2/force-v1 controls and persist the resolved mode
  in lifecycle state, status, health, helper namespace entry, and teardown.
- [x] Add safe host-network-only Docker policy plus explicit nft-first,
  force-nft, and force-legacy bridge modes with Android-global network warnings.
- [x] Preserve unmanaged or externally modified Docker daemon configuration,
  provide a separate live compatibility log, and pin fallback order/defaults in
  build-time regression tests.
- [ ] Verify Debian gate 2: BFU access to the selected Debian rootfs.
- [ ] Verify the namespace/mount/PID-1 Debian chroot probe on the target.
- [x] Promote the setup into an idempotent long-lived Debian launcher.
- [x] Start systemd as namespace PID 1 and verify D-Bus/systemctl.
- [x] Cold-boot enabled Debian SSH before first unlock.
- [ ] Run the agreed single physical validation session covering all remaining
  gates, five cold cycles, unlock continuity, normal Termux handoff, and shutdown
  isolation.

## Build environment note

The host defaults to JDK 26, so the reproducible build uses the repository's JDK
17 toolchain. Clean Java compilation, DEX packaging, native-helper verification,
lint, unit tests, and APK assembly pass. The current standalone artifact is
`dist/dawnshell_0.1.0_debug.apk` with SHA-256
`D919C19D5D75CB94B6313405A1D78F90B42C13DC1695662CB8BFDD6E0E659FE1`.
Whole debug APK hashes are build-specific because clean D8 runs can vary
synthetic-lambda metadata; the final harness therefore records the local hash and
requires the installed APK to match it. The BFU helper is rebuilt from the
checked-in native source and packaged with the APK; no historical fixed helper
digest is maintained.

The Direct Boot and namespace foundation was validated on the physical target by
the device owner. Magisk root was subsequently proven entirely during BFU and the
Debian 13 rootfs installation completed. Per the agreed order, the next device
action is the single integrated `scripts/test-final-bfu.sh` session after this APK
is installed; no intermediate device result is required for source completion.

The former Termux/Termux:Boot install pair below is retained only as historical
PoC evidence and is not required by the standalone DawnShell APK:

```text
31B9A5166CC0C3912D3840D5F14A640C841E1F259886372A5173B0FF88E0A1C6  termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk
C60438F14B363CAE9D398F3493BA0279B86E0D3511C9850E6B7027FA9491DC06  termux-boot_0.8.1_bfu_debug.apk
```

## 2026-08-23 integrated physical cycle

One cold cycle passed on the currently connected device, which Android identifies
as `SM-N770F` / `r7` with Linux 4.4.302 (distinct from the original SM-N950N
target). Before first unlock, Android boot ID
`1af84e87-c02b-4256-9e32-47a701351f55` accepted public-key SSH on TCP 22 and
reported systemd PID 1 start ticks `3740`, system state `running`, active D-Bus,
`ssh.service`, boot-proof service, and `multi-user.target`. The required `id`,
`uname`, `uptime`, `ip`, and `/proc/meminfo` commands succeeded over SSH.

This ROM exposes the provisioned normal-Termux CE sentinel while
`UserManager.isUserUnlocked()` is false. The default gate correctly blocked that
condition; the operator then explicitly enabled the DE-backed unsafe override.
The successful cycle persisted `CE_ISOLATION_OVERRIDE_USED`, locked-state root,
rootfs and namespace probes, and a successful locked-boot lifecycle record.
After unlock, the same systemd start ticks, machine ID, Android boot ID, SSH,
D-Bus, and proof service remained active. `USER_UNLOCKED` left Debian unchanged,
normal Termux handoff ran once, duplicates were suppressed, and its test marker
contained the same Android boot ID. The ROM delayed the JobScheduler handoff by
about 72 seconds, so the harness now waits up to 120 seconds for that marker.
