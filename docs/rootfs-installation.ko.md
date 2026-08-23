# Debian rootfs 설치

[English](rootfs-installation.md)

## 목적과 경계

런처에서 gate 2 rootfs를 `/data/local/debian`에 설치할 수 있다. 부트스트랩은
Termux, 다른 패키지, CE 저장소를 사용하지 않고 DawnShell이 Device Protected
`files/bfu/`에 프로비저닝한 ABI별 Bionic 런타임으로 실행된다.

## 최초 1회 준비

DawnShell을 열고 **Magisk 루트 권한 요청 / 확인**을 누른다. 패키지 목록에
신뢰한 독립 앱만 있는지 확인하고 Magisk에서 영구 허용을 선택한다.
**Direct Boot Debian 부트스트랩 사용**을 켠 뒤
**Debian 13 Trixie rootfs 설치**를 누른다. Activity가 background로 가도
foreground service가 계속 작업하지만 화면을 유지하면 최신 48 KiB 로그가
1초마다 갱신된다.

## 소스 빌드 host 런타임과 검증 입력

| Android ABI | Debian 아키텍처 |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

`scripts/build-bootstrap-runtime.sh`는 3개 ABI 모두에 BusyBox 1.38.0,
base-installer 1.226의 `pkgdetails`, 정적 의존성을 포함한 GnuPG 2.4.9 `gpgv`,
네이티브 namespace launcher를 빌드한다. 각 산출물은 Android PIE이고
`/system/bin/linker` 또는 `linker64`를 쓴다. 허용하지 않은 shared dependency나
고정 app-data path가 있으면 빌드를 거부한다.

APK에는 다음 architecture-independent 입력이 정확히 포함된다.

| Artifact | SHA-256 |
| --- | --- |
| `debootstrap_1.0.141.tar.gz` | `232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b` |
| `debian-archive-keyring_2025.1_all.deb` | `9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac` |

Android asset packager가 `.gz`를 자동 처리하지 못하게 APK 내부에서는
`debootstrap_1.0.141.tgz`로 저장하지만 DE runtime 이름은 원래 `.tar.gz`다.

네이티브 빌드 전 소스 SHA-256을 검사하고 APK 서명이 산출물을 보호한다.
프로비저닝은 입력을 앱 DE로 원자 복사한다. root helper가 digest를 다시
검사하고 Trixie archive keyring을 추출해 debootstrap을 `--force-check-sig`로
호출한다. checksum이나 Debian Release 서명 실패는 즉시 중단한다.

BusyBox compact TLS client가 peer 인증을 하지 않으므로 package mirror 전송은
HTTP다. 대신 소스 빌드 `gpgv`가 Debian Release metadata를 검증하고,
debootstrap이 signed metadata의 Packages index와 각 `.deb` hash를 검사하므로
전송 변조는 fail-closed한다. host `dpkg` 자동 탐색 대신 debootstrap의 문서화된
`arch` 파일과 네이티브 `pkgdetails`를 제공한다. `.deb`는 upstream `ar`
extractor와 BusyBox `ar`/`xzcat`/`tar`로 처리하며 BusyBox `dpkg-deb`는 지원되는
keyring package 추출에만 사용한다.

## 게시와 멱등성

설치는 사전 승인 Magisk root로 private mount namespace에서 실행된다.

```text
APK assets -> <DE filesDir>/bfu/{bin,downloads}/ 검증 파일
  -> /data/local/debian.installing
  -> Debian 13/Trixie, 선택 architecture, dpkg DB,
     /bin/sh, root ownership 검증
  -> .dawnshell-rootfs metadata marker 기록
  -> /data/local/debian으로 atomic rename
```

debootstrap 전 `mount --make-rprivate /`를 실행한다. 기존
`/data/local/debian`을 덮어쓰지 않는다. 유효한 기존 Trixie rootfs는
`ALREADY_INSTALLED`, 다른 suite marker나 알 수 없는 target은 보존 후 hard
failure다. in-place Debian release upgrade는 하지 않는다.

`/data/local/.dawnshell-debian-install.lock`이 동시 설치를 막는다. 현재 installer
PID와 일치하는 lock은 active로 처리하고 stale lock은 삭제 대신 timestamp를
붙여 rename한다. 중단된 staging tree도 다음 시도에서
`/data/local/debian.failed.<epoch>`로 보존한다. 일반 debootstrap 실패는 진단을
위해 `/data/local/debian.installing`을 남긴다.

## 실시간·영구 로그

UI는 다음 DE 파일을 1초마다 polling한다.

```text
<DE filesDir>/debian-install.status
<DE filesDir>/debian-install.log
```

**로그 → Debian 설치**에서 full-screen monospace 로그를 연다. 길게 눌러
선택·복사하거나 toolbar로 전체 visible tail을 복사할 수 있다. 선택 중이거나
bottom 위로 스크롤한 동안 refresh/follow를 멈추고 선택 해제 또는 bottom 복귀
후 재개한다.

로그에는 Android/Debian architecture, integrity 검사, `su` 경로, private mount,
debootstrap stdout/stderr, 검증, atomic promotion을 기록한다. environment dump,
credential, private key는 기록하지 않는다. root helper 실패 시 숫자 status뿐
아니라 마지막 정제된 `ERROR:`도 installer status에 포함한다.

debuggable 빌드에서는 unlock 후 다음처럼 읽을 수 있다.

```sh
adb shell run-as me.aroxu.dawnshell cat \
  /data/user_de/0/me.aroxu.dawnshell/files/debian-install.status
adb shell run-as me.aroxu.dawnshell cat \
  /data/user_de/0/me.aroxu.dawnshell/files/debian-install.log
```

위 literal path는 user 0 진단 예시일 뿐이며 runtime은 항상 DE Context API로
경로를 계산한다.

## 실패 처리

- `source-built ... is missing`: 앱에서 runtime을 다시 프로비저닝한다. 계속
  발생하면 APK에 기기 ABI가 없거나 불완전한 것이므로 로그를 보존한다.
- checksum/signature 실패: 검증을 우회하지 말고 로그와 network/cache를 조사한다.
- 검증되지 않은 `/data/local/debian` 존재: 출처를 확인하기 전 삭제·이동하지
  않는다. installer는 이를 지우지 않는다.
- partial staging 존재: 수동 정리 전 `debootstrap/debootstrap.log`를 보존한다.
  다음 앱 시도가 자동으로 timestamp sibling으로 옮긴다.
- `stat: invalid option -- c`: 최신 APK는 BusyBox
  `CONFIG_FEATURE_STAT_FORMAT`을 포함하고 다운로드 전에 `stat -c` preflight를
  수행한다. 이전 APK의 staging tree는 보존한 채 업데이트 후 재시도한다.
- Android locked: interactive install은 Magisk 정책, 파괴적 게시, progress UI를
  명시적으로 다루기 위해 AFU-only다. CE 도구는 쓰지 않는다.

`INSTALL_SUCCEEDED` 뒤 unlock하지 않고 재부팅해
`scripts/test-rootfs-bfu.sh`를 실행한다. AFU 설치 성공만으로 BFU 접근성을
증명할 수 없으며 새 locked-boot 증거가 gate 2를 완료한다.
