# DawnShell

[English](README.md)

[![빌드 및 릴리스](https://github.com/aroxu/dawnshell/actions/workflows/build.yml/badge.svg)](https://github.com/aroxu/dawnshell/actions/workflows/build.yml)

DawnShell은 Android를 재부팅한 뒤 화면 잠금을 처음 풀기 전에도 Debian 13과
SSH 서버를 시작하는 앱입니다. 앱 패키지 이름은 `me.aroxu.dawnshell`입니다.

처음 사용하신다면 다음 순서로 읽어 주세요.

1. [설치 가이드](docs/installation.ko.md)에서 APK 설치와 최초 설정을 진행합니다.
2. [사용자 매뉴얼](docs/user-guide.ko.md)에서 서버 제어와 SSH 접속 방법을 확인합니다.
3. 모르는 약어가 나오면 [쉬운 용어집](docs/glossary.ko.md)을 참고합니다.

## 어떤 앱인가요?

Android는 재부팅 직후 사용자가 PIN, 패턴 또는 비밀번호를 처음 입력하기 전에는
일반 앱 데이터를 열지 않습니다. 이 상태를 BFU(Before First Unlock, 최초 잠금
해제 전)라고 부릅니다. DawnShell은 Android의 공식 Direct Boot 기능을 사용해
BFU에서도 필요한 최소 파일만 읽고 Debian을 시작합니다.

- [Google: Direct Boot 지원 방법](https://developer.android.com/privacy-and-security/direct-boot)
- [AOSP: 파일 기반 암호화](https://source.android.com/docs/security/features/encryption/file-based)

사용자가 잠금을 풀어 AFU(After First Unlock, 최초 잠금 해제 후)가 되어도 같은
Debian 인스턴스가 계속 실행됩니다. 잠금 해제 이벤트가 서버를 중지하거나 다시
시작하지 않습니다.

## 주요 기능

- Debian 13 Trixie rootfs를 앱에서 설치하고 검증합니다.
- BFU에서 `systemd`와 공개 키 전용 OpenSSH 서버를 시작합니다.
- Wi-Fi, 모바일 데이터, USB Ethernet 등 Android 네트워크 인터페이스를 공유합니다.
- Material 3 화면에서 설치, 설정, 시작, 중지, 상태 확인, 계정과 SSH 키를 관리합니다.
- 각 작업의 실시간 로그를 별도 화면에서 선택하고 복사할 수 있습니다.
- ARM 32비트, ARM 64비트, x86 64비트 Android 기기를 지원합니다.

## 중요한 보안 경계

DawnShell은 다음 세 저장 위치를 구분합니다.

| 위치 | 언제 열리나요? | 저장하는 내용 |
| --- | --- | --- |
| 앱 DE(Device Encrypted) | PIN 입력 전부터 | 부팅 설정, 공개 키, 로그, 최소 실행 파일 |
| 앱 CE(Credential Encrypted) | 첫 잠금 해제 후 | SSH 클라이언트 개인 키 |
| `/data/local/debian` | root 권한으로 접근 | Debian 전체 rootfs |

DE와 CE의 뜻은 [쉬운 용어집](docs/glossary.ko.md#android-부팅과-저장소)에서
예시와 함께 확인할 수 있습니다. Google은 Direct Boot에서 꼭 필요한 정보만 DE에
저장하고, 비밀번호나 토큰 같은 개인 정보는 CE에 보관하도록 안내합니다.

SSH는 기본 TCP 22 포트에서 `debian` 계정의 공개 키 인증만 허용합니다. SSH
비밀번호 인증과 SSH를 통한 root 직접 로그인은 꺼져 있습니다. 로컬 root
비밀번호를 설정한 뒤에는 SSH로 접속한 `debian` 사용자가 `su root`를 실행해
root로 전환할 수 있습니다.

Debian root는 Android 커널과 네트워크를 공유합니다. 일반 가상 머신처럼 완전히
격리된 환경이 아니므로, 신뢰할 수 있는 서비스와 명령만 실행해 주세요.

## 지원 환경

- Android 7.0(API 24) 이상
- FBE(File-Based Encryption, 파일 기반 암호화)를 사용하는 기기
- Magisk 또는 호환되는 `su`
- DawnShell에 대한 영구 root 승인
- 다음 ABI(Application Binary Interface, CPU용 실행 파일 규칙) 중 하나

| Android ABI | Debian 아키텍처 |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

[Google의 Android ABI 문서](https://developer.android.com/ndk/guides/abis)에서
각 이름의 의미를 확인할 수 있습니다.

## 동작 흐름

```text
Android 부팅
  → LOCKED_BOOT_COMPLETED 수신
  → 앱의 DE 저장소와 root 권한 확인
  → /data/local/debian 검증
  → 전용 mount/PID/UTS/cgroup namespace 준비
  → Debian systemd를 PID 1로 시작
  → OpenSSH 서버 시작

사용자가 처음 잠금을 해제함
  → USER_UNLOCKED 기록
  → 실행 중인 Debian과 SSH는 그대로 유지
```

`LOCKED_BOOT_COMPLETED`와 `USER_UNLOCKED`는 Android가 보내는 부팅 알림입니다.
자세한 설명은 [Google Intent API](https://developer.android.com/reference/android/content/Intent#ACTION_LOCKED_BOOT_COMPLETED)와
[Direct Boot 문서](https://developer.android.com/privacy-and-security/direct-boot#get_notified_of_user_unlock)를 참고해 주세요.

## 커널과 Docker

DawnShell은 커널 버전 이름만 보고 동작을 결정하지 않습니다. 실제 기기에서
cgroup(control group, 프로세스 자원 관리 기능) v2를 먼저 시험하고, 지원이
부족하면 v1 방식으로 전환합니다. 기본값인 **자동: v2 → v1**을 권장합니다.

Docker 기본값은 **안전한 호스트 네트워크만 사용**입니다. 이 모드에서는
컨테이너를 `--network host`로 실행합니다. Docker bridge는 Android의 전역
방화벽, NAT(Network Address Translation), 경로 설정을 바꿀 수 있으므로 앱의
경고를 읽고 별도 복구 수단이 있을 때만 사용해 주세요.

## 빌드

필요한 도구는 다음과 같습니다.

- JDK 17
- Android SDK Platform 34
- Android NDK `29.0.14206865`
- Bash, GNU make, C 컴파일러, Autoconf, Automake, libtool, Bison, GNU gettext,
  GNU awk, patch, sed, tar, coreutils
- Windows에서는 위 도구가 설치된 MSYS2

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
./scripts/build-all.sh
```

빌드는 기본적으로 `make -j"$(nproc)"`를 사용합니다. 작업 수를 제한하려면
`DAWNSHELL_BUILD_JOBS`를 설정합니다. 기본 APK는 `dist/dawnshell_0.2.0_debug.apk`에
생성됩니다.

공개 debug 키는 개발과 시험에만 사용해 주세요. 배포용 APK는 개인 서명 키로
서명해야 합니다. Android 앱 서명이 낯설다면
[Google 앱 서명 안내](https://developer.android.com/studio/publish/app-signing)를 참고해 주세요.

## GitHub Actions와 Release

`.github/workflows/build.yml`은 push, pull request, 수동 실행에서 세 ABI의 내장
도구와 Android 앱을 빌드하고 검사합니다. Artifact에는 APK, 대응 소스,
라이선스, 빌드 정보와 `SHA256SUMS`가 포함됩니다.

`vMAJOR.MINOR.PATCH` 형식의 태그를 push하면 GitHub Release 배포 작업이
실행됩니다. 정식 배포에는 다음 Actions secret이 모두 필요합니다.

- `DAWNSHELL_RELEASE_KEYSTORE_BASE64`
- `DAWNSHELL_RELEASE_KEY_ALIAS`
- `DAWNSHELL_RELEASE_STORE_PASSWORD`
- `DAWNSHELL_RELEASE_KEY_PASSWORD`

```sh
git tag -s v0.2.0 -m "DawnShell 0.2.0"
git push origin v0.2.0
```

DawnShell 코드는 MIT 라이선스입니다. 내장 명령행 도구는 각 원저작자의
GPL/LGPL 등 별도 라이선스를 유지합니다. 자세한 내용은
[서드파티 고지](bfu-runtime/THIRD_PARTY_NOTICES.ko.md)와 `LICENSES/README.md`에서
확인할 수 있습니다.

## 더 자세한 문서

- [설치 가이드](docs/installation.ko.md)
- [사용자 매뉴얼](docs/user-guide.ko.md)
- [쉬운 용어집](docs/glossary.ko.md)
- [아키텍처](docs/architecture.ko.md)
- [보안 모델](docs/security.ko.md)
- [테스트 방법](docs/testing.ko.md)
- [rootfs 설치 과정](docs/rootfs-installation.ko.md)
- [Debian systemd 구성](docs/debian-systemd.ko.md)
- [개발 진행 상황](docs/progress.ko.md)
