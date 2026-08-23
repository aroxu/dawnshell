# 진행 상황

[English](progress.md)

## 독립 앱 분리 — 2026-08-23

- [x] 패키지 `me.aroxu.dawnshell`, 런처 이름 **DawnShell**인 독립 Android
  프로젝트 생성
- [x] `sharedUserId`, `BootJobService`, `TermuxService`, `~/.termux/boot`, Termux
  서명키 결합 제거
- [x] 독립 앱 CE sentinel 기반 격리 증거와 앱 소유 DE 설정·키·런타임·로그 유지
- [x] CE에서 랜덤 Ed25519 client identity 생성, 공개 절반만 DE/Debian으로
  프로비저닝하고 파일/Termux command export 제공
- [x] Android 상태, rootfs marker, systemd unit, runtime control, hostname, SSH
  artifact를 모두 DawnShell namespace로 전환
- [x] Debian 13 systemd/OpenSSH, 로컬 password, private-rootfs setuid,
  unlock 이후 지속 실행, 기존 `/data/local/debian` 유지
- [x] capability 기반 cgroup 선택: delegated v2 + 실제 cgroup-device BPF attach
  우선, 완전 정리 후 devices-v1 + `name=systemd` fallback
- [x] native health와 cold-boot harness가 검증된 v2 또는 v1 devices view만 허용
- [x] JDK 17 build/lint, target SDK 28, Direct Boot receiver/service, shared UID
  부재, APK Signature Scheme v2 확인
- [x] 앱 이름을 제외한 214개 UI 문자열 한국어 리소스 추가
- [x] installer/관리 script의 Termux `$PREFIX` 의존 제거, 앱 DE 자체 host tool 사용
- [x] BusyBox, debootstrap, base-installer, GnuPG와 library, Debian archive keyring
  소스·SHA-256·서드파티 고지 고정
- [x] `armeabi-v7a`/`armhf`, `arm64-v8a`/`arm64`, `x86_64`/`amd64` 재현 가능한
  소스 빌드와 APK runtime 선택
- [x] 앱·서드파티 라이선스 전문과 정확한 archive-keyring 대응 소스를 APK에
  포함하고 selectable license/source-offer 화면 추가
- [x] all-ABI 소스 빌드, Android 검사, private release signing, APK/source/license
  배포 묶음, checksum, tag release용 고정 GitHub Actions 추가
- [x] BusyBox formatted `stat`을 켜고 installer preflight에서 검사하여
  debootstrap 후 `stat -c` 실패 수정 및 staging 진단 보존
- [x] 실제 기기에서 Docker/containerd cgroup 초기화를 통과할 만큼 v1 devices
  delegation 검증. 다음 실패는 kernel과 맞지 않는 nftables frontend였음
- [ ] 새 network backend negotiation과 BFU cold cycle 5회 검증

현재 staged APK: `dist/dawnshell_0.2.0_debug.apk`

기록된 SHA-256:
`5631AA1152FC7F41910B07D6F30996E0F80BB0D7DDFEDBAFF5FA429F3AFD815F`

아래는 독립 DawnShell 이전의 BFU Termux:Boot PoC 이력이다.

## 2026-08-22

- [x] termux-app, termux-boot, termux-packages 최신 master clone과 HEAD 고정
- [x] Termux/Boot target SDK 28, shared UID `com.termux`, 동일 debug keystore 확인
- [x] `BootReceiver -> JobScheduler -> BootJobService -> TermuxService` 추적 및
  Termux CE/prefix 하드코딩 확인
- [x] runtime receiver가 필요한 `USER_UNLOCKED` 동작 확인
- [x] Direct-Boot-aware receiver/foreground service, DE 설정 UI/layout, DE 직접
  executable probe 추가
- [x] AFU scheduling 보존과 boot/unlock 중복 방지
- [x] 모든 `LOCKED_BOOT_COMPLETED`를 DE `bfu-boot.log`에 기록하고 test script로 검증
- [x] Android command-line tools SHA-256 검증, JDK 17/SDK 34 Boot APK build/sign
- [x] manifest/target SDK/Direct Boot/signature 검증, lint 0 error, unit-test task 실행
- [x] Android Platform 36, Build Tools 35/36, NDK 29.0.14206865 설치
- [x] Termux 0.118.0 split/universal debug APK와 Note 8 ARM64 artifact 빌드
- [x] Termux와 Boot APK의 target SDK/shared UID/certificate digest 일치 확인
- [x] SM-N950N Android 16에서 locked broadcast, DE, foreground service, DE native
  실행, unlock handoff 실기기 검증
- [x] Linux 4.4.302에서 PID/mount/UTS/cgroup namespace와 isolated `/proc` PID 1
  helper 검증. vendor kernel 때문에 Android IPC 유지
- [x] Dropbear milestone을 Debian/systemd 목표로 교체
- [x] bounded BFU `su -c id`, DE root log, unlock 후 read-only 결과 UI 추가
- [x] unlock 때 BFU service를 중지하지 않고 AFU handoff만 수행
- [x] 기기에서 `/system/xbin/su`, uid 0, Magisk context, locked 전후 상태로 gate 1 검증
- [x] AFU-only Magisk 승인 버튼과 BFU 증거와 구분되는 log 추가
- [x] `/data/local/debian` 구조/shell/RW probe와 DE 결과 구현
- [x] 초기 gate 2 실패가 root/DE/SELinux가 아닌 `stage=root_missing`임을 확인
- [x] 고정 artifact, signature 강제, private mount, staging 검증, overwrite 금지
  upstream rootfs installer 추가
- [x] fresh install을 Debian 13 Trixie ARM64와 release-native debootstrap/keyring으로 전환
- [x] DE installer status/log, 1초 live tail, 선택·복사 console과 follow pause 추가
- [x] 당시 Termux `mount-utils` 전제와 정제된 root helper `ERROR:` 전달 추가
- [x] vendor Android 16 forced-scrollbar crash 회피하면서 touch scroll/text select 유지
- [x] Android `mksh`가 target-only `PATH`를 유지해 host helper가 toybox로 바뀌고
  잘못된 `https:__..._Packages`를 찾던 첫 Trixie bootstrap 실패 진단
- [x] target command를 subshell로 제한해 host PATH를 보존하고 debootstrap log tail 표시
- [x] root 승인, BFU probe, provision, Debian status/output을 독립 selectable console로 표시
- [x] credential 없이 DE-only 48 KiB live tail 유지

## 2026-08-23

- [x] 실기기 Debian 13 Trixie rootfs 설치 완료
- [x] CE-independent ARM64 namespace/chroot probe, native asset SHA-256, strict rootfs
  validation, private mount, bounded execution 추가
- [x] probe console과 자동 cold-boot evidence script 추가
- [x] lifetime lock, graceful systemd exit, stale/orphan detection, DE checkpoint를 가진
  native `start/status/stop` 구현
- [x] network namespace나 Android controller root 노출 없이 private v1
  `name=systemd`와 systemd 257 legacy-force 추가
- [x] DE public key와 AFU-only Debian systemd/D-Bus/public-key-only OpenSSH 구성
- [x] locked gate 뒤 Debian 자동 시작 및 `USER_UNLOCKED` 이후 동일 instance 유지
- [x] 설정/lifecycle live log와 start/status/graceful-stop 제어 추가
- [x] unlock 전후 Debian PID 1 identity 비교 BFU SSH end-to-end test 추가
- [x] readable CE와 빈 mount stub을 구분하는 fail-closed sentinel probe 추가
- [x] PID/mount/UTS/cgroup/IPC/network namespace inode 기록과 topology 요구
- [x] veth/NAT를 shared NIC와 Tailscale bypass-mark route watcher로 교체하고
  Wi-Fi/mobile/USB Ethernet 변화 및 bounded cleanup 지원
- [x] Android 전체 재부팅용 root-only fixed-token FIFO `reboot now` bridge 추가
- [x] systemd PID 1, D-Bus, target, independent proof unit, SSH/TCP 22 health 검사와
  locked DE 증거 추가
- [x] default-target 이름뿐 아니라 실제 `multi-user.target` active 요구
- [x] restart, private rootfs bind, read-only `/sys`, boot-ID별 Termux handoff dedup 추가
- [x] 제한된 poweroff/reboot/shutdown isolation test와 기본 5-cycle 최종 harness 추가
- [x] AFU `BOOT_COMPLETED` service 재생성이 BFU probe 증거를 오염하지 않게 수정
- [x] 설치 APK와 local staged artifact/helper digest 일치 검증 추가
- [x] 실기기 AFU 재구성 문제 수정: 실제 `/usr/bin/mawk` 검사와 `sshd -t` 전
  `/run/sshd` 생성
- [x] pstore로 Samsung 4.4 IPC namespace kernel panic 경로 식별
- [x] 모든 `CLONE_NEWIPC` 제거와 build-time regression check, shared IPC 요구
- [x] console getty mask 및 실기기 systemd/D-Bus/proof/TCP22/public-key SSH 증명
- [x] hanging halt signal 대신 systemd container `exit` 사용, 0.76초 stop,
  `wait_status=0`, Android boot ID 불변 검증
- [x] Termux CE private-key import/localhost SSH command와 DE private-key 부재 검증
- [x] AFU-only local password와 private-rootfs setuid `su root`, SSH public-key-only 유지
- [x] 기존 programmatic Termux UI를 전체 Material 3 dashboard로 교체
- [x] CE-readable override를 Direct Boot 카드에 복원하고 미적용 switch 상태 표시
- [x] 모든 log를 live index와 full-screen selectable/copyable reader로 분리
- [x] AndroidX automatic startup/profile component 제거
- [x] private mount의 devices-v1 hierarchy와 전용 child delegation/health/teardown 추가
- [x] kernel version 가정 대신 v2+BPF 우선, 정리 후 v1 fallback capability negotiation
- [x] DE auto/force-v2/force-v1 UI와 resolved mode 저장
- [x] safe host-only Docker와 명시적 nft/nft-iptables/legacy bridge 정책 및 경고
- [x] unmanaged/외부 변경 daemon config 보존, 별도 compatibility log, fallback test
- [x] 실제 kernel `addrtype` 실패 후 `addrtype`/`MASQUERADE`/`conntrack` probe 강화
- [ ] 선택 rootfs의 BFU gate 2 재검증
- [ ] 대상 namespace/mount/PID-1 chroot probe 재검증
- [x] idempotent 장기 Debian launcher 구현
- [x] namespace PID 1 systemd와 D-Bus/systemctl 검증
- [x] 최초 unlock 전 cold-boot SSH 구현
- [ ] 남은 gate, cold cycle 5회, unlock 연속성, shutdown 격리를 한 번에 검증

## 빌드 환경 메모

host 기본 JDK가 26이라 저장소 JDK 17 toolchain을 쓴다. clean Java compile,
DEX, native helper 검증, lint, unit test, APK assemble이 통과한다. debug APK
전체 hash는 D8 synthetic lambda metadata에 따라 clean build별로 달라질 수 있어
최종 harness가 local hash와 설치 APK byte equality를 기록·검사한다. helper도
체크인된 네이티브 소스에서 다시 빌드하며 역사적 고정 digest를 두지 않는다.

Direct Boot와 namespace 기반은 기기 소유자가 실기기에서 검증했다. Magisk
root도 BFU 안에서 증명됐고 Debian 13 rootfs 설치가 완료됐다. 다음 기기 작업은
고정 APK 설치 후 `scripts/test-final-bfu.sh` 단일 통합 세션이다.

이전 Termux/Boot pair는 역사적 PoC 증거일 뿐 DawnShell에 필요하지 않다.

```text
31B9A5166CC0C3912D3840D5F14A640C841E1F259886372A5173B0FF88E0A1C6  termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk
C60438F14B363CAE9D398F3493BA0279B86E0D3511C9850E6B7027FA9491DC06  termux-boot_0.8.1_bfu_debug.apk
```

## 2026-08-23 통합 물리 cycle

현재 연결 기기 `SM-N770F`/`r7`, Linux 4.4.302에서 cold cycle 1회가 통과했다.
최초 unlock 전 public-key SSH TCP 22, systemd PID 1, `running`, D-Bus,
`ssh.service`, proof service, `multi-user.target`, 기본 진단 명령이 성공했다.

이 ROM은 `UserManager.isUserUnlocked()==false`인데도 normal-Termux CE sentinel을
노출했다. 기본 gate가 이를 차단했고 사용자가 명시적으로 unsafe override를
켰다. 성공 cycle은 `CE_ISOLATION_OVERRIDE_USED`와 모든 locked gate를 기록했다.
unlock 뒤 systemd start ticks, machine ID, Android boot ID, SSH/D-Bus/proof service가
그대로 유지됐다. `USER_UNLOCKED`는 Debian을 바꾸지 않았고 normal Termux
handoff는 한 번만 실행됐다. ROM의 JobScheduler가 약 72초 늦어 harness timeout을
120초로 조정했다.
