# DawnShell

[English](README.md)

[![빌드 및 릴리스](https://github.com/aroxu/dawnshell/actions/workflows/build.yml/badge.svg)](https://github.com/aroxu/dawnshell/actions/workflows/build.yml)

처음 사용하는 경우 [설치 가이드](docs/installation.ko.md)를 먼저 읽고, 설치
후 운영 방법은 [사용자 매뉴얼](docs/user-guide.ko.md)을 참고한다.

DawnShell은 root 소유 Debian 13 Trixie 환경을 Android 최초 잠금 해제 전부터
실행하는 독립 Direct Boot 컨트롤러다. Android 패키지는
`me.aroxu.dawnshell`, 런처 이름은 **DawnShell**이다.

Direct Boot와 내장 네이티브 부트스트랩 런타임을 모두 제공하는 최초 버전에
맞춰 최소 Android 버전은 7.0/API 24다.

앱은 최초 Android 잠금 해제 전에 Debian systemd와 공개 키 전용 OpenSSH를
시작한다. `USER_UNLOCKED` 이후에도 같은 Debian 인스턴스가 계속 실행된다.
일반 Termux의 `~/.termux/boot` 스크립트나 `TermuxService`는 호출하지 않으므로
AFU Termux 자동 시작이 필요하면 업스트림 Termux:Boot를 별도로 사용한다.

## 경계

- `sharedUserId`가 없으며 DawnShell 전용 Android UID와 Magisk 정책을 쓴다.
- 제어 파일, 공개 authorized key, 로그는
  `createDeviceProtectedStorageContext()`가 반환한 앱 전용 DE 저장소에 둔다.
- Debian rootfs는 `/data/local/debian`에 있으며 CE/DE로 복사하지 않는다.
- OpenSSH는 TCP 22에서 등록된 공개 키만 받는다. 비밀번호 인증과 root SSH
  로그인은 비활성화된다.
- AFU 제어에서 로컬 `debian`/`root` 비밀번호를 설정할 수 있다. 이후
  private rootfs mount의 setuid `su root`를 쓸 수 있지만 Android 호스트
  `/data` mount 자체는 절대 remount하지 않는다.
- 설치와 관리 작업은 모두 앱 DE에 프로비저닝된 ABI별 소스 빌드 도구를
  사용한다. 다른 패키지 바이너리나 Termux CE를 실행·열람하지 않는다.

## 독립 부트스트랩 런타임

Termux 없이 Debian을 설치, 설정, 부팅, 복구, 삭제할 수 있다. Universal APK는
`Build.SUPPORTED_ABIS`에 따라 다음 런타임을 선택한다.

| Android ABI | Debian 아키텍처 |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

각 ABI에는 Bionic PIE BusyBox, Debian base-installer의 `pkgdetails`, 의존성을
정적으로 연결한 `gpgv`, DawnShell namespace 런처가 포함된다. APK에는 고정된
debootstrap 소스와 Debian 공개 archive keyring도 들어 있다. 부트스트랩 과정은
Debian Release 서명, package index, package hash를 검증한다.

Termux는 같은 기기에서 쓰기 편한 선택적 SSH 클라이언트일 뿐이다. 앱이
내보내는 키 가져오기/localhost 접속 명령은 Termux용이지만, 내보낸 키는 어떤
OpenSSH 클라이언트에서도 사용할 수 있다.

## 구현 흐름

```text
LOCKED_BOOT_COMPLETED
  -> directBootAware BootReceiver
  -> directBootAware foreground service
  -> 앱 소유 CE 격리 sentinel 검사
  -> 사전 승인된 Magisk root 검사
  -> /data/local/debian rootfs gate
  -> private mount/PID/UTS/cgroup namespace
     (Samsung Linux 4.4 호환성을 위해 Android IPC/network 유지)
  -> capability 기반 cgroup 선택
     (delegated v2 + device BPF 우선, 격리된 v1 fallback)
  -> Android NIC 직접 공유 + Tailscale fwmark route shim
  -> Debian 13 systemd를 namespace PID 1로 시작
  -> D-Bus + ssh.service + boot-proof service

USER_UNLOCKED
  -> 이벤트 기록
  -> 동일한 Debian/systemd/SSH 인스턴스 유지
```

Material 3 대시보드에서 rootfs 설치, 시스템 설정, 수명주기, 계정, SSH 키를
관리한다. 로그는 별도 인덱스와 전체 화면의 선택·복사 가능한 실시간 뷰로
표시한다. localhost SSH 명령 복사, Android 전체를 재부팅하는 root 전용
`reboot now` bridge, `/data/local/debian`만 영구 삭제하는 2단계 파괴적 제어도
제공한다. 클라이언트 private key는 앱 CE에만 있고 공개 키만 DE와 Debian으로
이동한다.

## 호환성과 마이그레이션

이전 BFU Termux:Boot 빌드와 자동 호환·마이그레이션하지 않는다. 패키지,
DE/CE 상태, rootfs marker, systemd unit, hostname, 제어 파일, SSH identity,
APK 이름 모두 DawnShell namespace를 사용한다. 수동 마이그레이션 전 이전
supervisor를 중지하고 같은 `/data/local/debian`에 두 supervisor를 동시에
실행하지 않는다.

## 커널 및 Docker 호환성 정책

커널 버전표가 아니라 실제 capability를 검사한다. 기본 cgroup 정책은 private
delegated cgroup v2 subtree를 먼저 만들고 임시 cgroup-device BPF program의
load/attach가 성공할 때만 채택한다. 실패하면 모두 정리한 뒤 cgroup v1
`devices`와 `name=systemd` 구현으로 fallback한다. UI에는 진단용 force-v2와
force-v1도 있다.

Docker 기본값은 **안전한 host-network-only**다. 관리되는 daemon 설정에서
bridge, iptables/ip6tables, forwarding, masquerading을 끄므로 컨테이너는
`--network host`를 써야 한다. 자동 bridge 모드는 Docker 29 native nftables,
`iptables-nft`, `iptables-legacy` 순서로 실제 요구 기능을 검사한다. 모두
실패하면 안전 모드로 돌아가며 강제 모드는 fail-closed한다.

Debian이 Android network namespace를 공유하므로 bridge 모드는 Android 전역
firewall, NAT, route, forwarding을 바꿔 Wi-Fi, 모바일 데이터, USB Ethernet,
VPN, Tailscale, SSH를 끊을 수 있다. 저장만으로 적용되지 않으며 AFU의 별도
적용 버튼을 눌러야 한다. 관리되지 않은 `/etc/docker/daemon.json`은 덮어쓰지
않고, DawnShell이 만든 파일도 기록된 SHA-256이 일치할 때만 교체한다.

## 빌드

요구 사항:

- JDK 17
- Android SDK Platform 34
- Android NDK `29.0.14206865`
- Bash, GNU make, host C compiler, GNU awk, patch, sed, tar, coreutils
- Windows에서는 위 도구가 설치된 MSYS2

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
./scripts/build-all.sh
```

`scripts/build-bootstrap-runtime.sh`는 vendored source SHA-256을 확인한 뒤 3개
ABI를 모두 빌드한다. 대상 제한은 공백 구분 `DAWNSHELL_BOOTSTRAP_ABIS`로 한다.
컴파일 병렬도는 기본 `make -j"$(nproc)"`이며 `DAWNSHELL_BUILD_JOBS`로 제한할
수 있다. 검증된 런타임 asset이 이미 있을 때만
`DAWNSHELL_SKIP_BOOTSTRAP_SOURCE_BUILD=1`을 사용한다.

소스와 URL은 `bfu-runtime/sources/SOURCES.lock`, 패치와 설정은
`bfu-runtime/patches`, `bfu-runtime/config`에 있다. DawnShell 코드는 MIT이고
내장 명령행 도구는 각 GPL/LGPL 라이선스를 유지한다. 자세한 내용은
[서드파티 고지](bfu-runtime/THIRD_PARTY_NOTICES.ko.md)를 참고한다.

기본 산출물:

```text
dist/dawnshell_0.2.0_debug.apk
```

debug keystore는 공개되어 있으므로 제품 배포에 쓰면 안 된다. 제품 빌드는
private key로 서명해야 한다. shared UID가 없으므로 Termux/Termux:Boot 키와
일치할 필요는 없다.

## GitHub Actions와 릴리스

`.github/workflows/build.yml`은 push, pull request, 수동 실행에서 모든 네이티브
도구를 고정 소스로 다시 빌드하고 Android lint/test/build, APK 서명, 내장
라이선스를 검사한다. Artifact에는 APK, 해당 commit의 정확한 대응 소스,
라이선스 묶음, 빌드 정보, 릴리스 노트, `SHA256SUMS`가 함께 들어간다.

`vMAJOR.MINOR.PATCH` tag는 GitHub Release를 추가로 생성한다. tag 빌드에는
다음 Actions secret 네 개가 모두 필요하다.

- `DAWNSHELL_RELEASE_KEYSTORE_BASE64`
- `DAWNSHELL_RELEASE_KEY_ALIAS`
- `DAWNSHELL_RELEASE_STORE_PASSWORD`
- `DAWNSHELL_RELEASE_KEY_PASSWORD`

keystore는 한 줄 Base64로 첫 secret에 저장하고 네 값 모두 Git 밖에서
보관한다. 설정 후 서명 tag를 push하면 된다.

```sh
git tag -s v0.2.0 -m "DawnShell 0.2.0"
git push origin v0.2.0
```

워크플로는 draft release를 만든 뒤 다운로드한 artifact의 checksum을 다시
검증하고 게시한다. 로컬 clean commit에서도 `scripts/package-release.sh`로
동일한 배포 묶음을 만들 수 있다.

`scripts/install.sh`는 APK를 `/sdcard/Download`로 push만 한다. 설치, uninstall,
데이터 삭제는 하지 않는다.

## 검증

최종 harness의 기본값은 cold boot 5회다.

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/dawnshell-ed25519 \
BFU_EXPECT_CE_READABLE_OVERRIDE=1 \
./scripts/test-final-bfu.sh
```

BFU SSH/systemd, unlock 연속성, 단일 systemd 인스턴스, APK와 프로비저닝된
helper 일치, 메모리 증거, poweroff/reboot/shutdown namespace 격리를 검사한다.
정상 상태는 delegated unified-v2 root 또는 delegated v1 devices view 중 하나를
요구한다. 일반 Termux:Boot handoff는 별도 업스트림 앱의 책임이므로 검사하지
않는다.

네트워크 관리자는 Android가 선택한 table을 추적하고 Tailscale Linux bypass
mark만 해당 table로 보낸다. veth, NAT, forwarding은 사용하지 않는다. Wi-Fi,
모바일, USB Ethernet은 Debian 재시작 없이 hot-plug할 수 있지만 BFU 중 물리
인터페이스 연결과 주소 할당은 ROM이 제공해야 한다.

세부 문서:

- [아키텍처](docs/architecture.ko.md)
- [보안 모델](docs/security.ko.md)
- [테스트 계획](docs/testing.ko.md)
- [rootfs 설치](docs/rootfs-installation.ko.md)
- [Debian systemd](docs/debian-systemd.ko.md)
- [진행 상황](docs/progress.ko.md)
