# DawnShell

[English](README.md) · [문서 홈](docs/README.ko.md) · [Release](https://github.com/aroxu/dawnshell/releases)

[![빌드 및 릴리스](https://github.com/aroxu/dawnshell/actions/workflows/build.yml/badge.svg)](https://github.com/aroxu/dawnshell/actions/workflows/build.yml)

**DawnShell은 root 권한이 있는 Android에서 재부팅 후 첫 잠금 해제 전부터 Debian
13 서버를 시작하는 앱입니다.** BFU 상태에서 SSH로 접속할 수 있고, Android 잠금을
푼 뒤에도 같은 Debian `systemd` 인스턴스가 계속 실행됩니다.

```text
Android 부팅
  → LOCKED_BOOT_COMPLETED
  → root와 Device Encrypted 런타임 검증
  → Debian 13 systemd 시작
  → TCP 22의 공개 키 전용 OpenSSH 시작

첫 잠금 해제
  → USER_UNLOCKED 기록
  → 기존 Debian과 SSH를 중지하지 않고 그대로 유지
```

패키지 이름: `me.aroxu.dawnshell`

> DawnShell은 영구 root 권한이 필수입니다. Debian은 Android 커널과 네트워크를
> 공유하며 일반 가상 머신처럼 완전히 격리되지 않습니다. 외부 서비스를 열거나
> 위험한 호환성 옵션을 켜기 전에 [보안 모델](docs/security.ko.md)을 읽어 주세요.

## 처음 시작하기

처음 사용한다면 다음 순서로 읽으면 됩니다.

1. [설치 가이드](docs/installation.ko.md) — APK 설치, root 승인, Debian 설치,
   SSH 구성과 첫 BFU 부팅 검증
2. [사용자 매뉴얼](docs/user-guide.ko.md) — 서버 제어, SSH, 계정, USB, 영상 가속,
   Docker, 로그, 백업과 삭제
3. [문제 해결 가이드](docs/troubleshooting.ko.md) — 증상별 점검 순서와 안전한 진단 명령

[문서 홈](docs/README.ko.md)에서는 하고 싶은 작업을 기준으로 모든 사용자·운영·개발
문서를 찾을 수 있습니다. 낯선 약어는 [쉬운 용어집](docs/glossary.ko.md)에 정리되어
있습니다.

## 주요 기능

- 고정하고 검증한 upstream 자료로 Debian 13 Trixie rootfs 설치
- `LOCKED_BOOT_COMPLETED`를 이용한 Android Direct Boot 자동 시작
- BFU에서 Debian `systemd`, D-Bus, 공개 키 전용 OpenSSH 실행
- `USER_UNLOCKED` 뒤에도 하나의 Debian 인스턴스를 계속 유지
- `armeabi-v7a`, `arm64-v8a`, `x86_64`용 부트스트랩 런타임 소스 빌드
- Wi-Fi, 모바일 데이터, VPN, USB Ethernet을 포함한 Android 네트워크 직접 공유
- 선택적인 raw USB 공유와 VID:PID 제한 독점 interface 패스스루
- cgroup v2 기능 검사와 검증된 cgroup v1 fallback
- Docker host network와 host IPC 호환성 정책
- Android MediaCodec을 이용한 실험적 AVC/HEVC decode·encode, Surface transcode,
  실시간 HLS와 USB 웹캠 인코딩
- 3D GPU와 영상 코덱 동작을 구분해 보여 주는 `gsmi`
- Material 3 관리 화면, 선택·복사 가능한 실시간 로그, 자동 생성 SSH 키, 로컬
  계정 암호 설정과 보호된 rootfs 삭제

## 지원 환경

| 조건 | 필요한 이유 |
| --- | --- |
| Android 7.0(API 24) 이상 | Direct Boot와 Device Encrypted 저장소 API 사용 |
| FBE(File-Based Encryption) | 잠금 전 DE와 잠금 후 CE 데이터 분리 |
| Magisk 또는 호환 `su` | Debian namespace와 rootfs 시작·관리 |
| DawnShell 영구 root 승인 | BFU에서는 대화형 승인 창을 표시할 수 없음 |
| `armeabi-v7a`, `arm64-v8a`, `x86_64` | APK에 포함된 CPU ABI |
| BFU에서 동작하는 네트워크 경로 | 첫 잠금 해제 전 원격 접속이 필요할 때만 해당 |

일부 ROM은 첫 잠금 해제 전 Wi-Fi를 복원하지 않습니다. DawnShell은 SSH listener를
계속 유지하지만 Android가 잠가 둔 네트워크 자격 증명을 대신 열 수는 없습니다.

## 안전한 기본값

| 설정 | 기본값 | 의미 |
| --- | --- | --- |
| Direct Boot Debian 부트스트랩 | 사용자가 켜기 전까지 끔 | 명시적인 설정 전에는 BFU 서버를 자동 시작하지 않음 |
| BFU CE 읽기 예외 | 끔 | 첫 잠금 해제 전 앱 CE가 읽히면 안전하게 시작 차단 |
| cgroup 정책 | 자동 v2 → v1 | 기능 검사가 모두 성공할 때만 v2 사용 |
| Docker 네트워크 | host network 전용 | Android 전역 방화벽과 route 변경 방지 |
| Docker host IPC 호환성 | 켬 | 일부 커널의 private IPC/mqueue 오류 회피, 대신 container 격리 감소 |
| raw USB 접근 | 끔 | `/dev/bus/usb`와 USB 문자 장치 major 189만 차단 |
| 하드웨어 영상 코덱 브리지 | 끔 | 사용자가 동의한 뒤에만 실험 기능 사용 |

Docker bridge, USB 독점 패스스루, CE 읽기 예외는 Android 전체에 영향을 줄 수
있습니다. 앱의 경고문은 반드시 읽고 독립된 복구 수단을 준비하세요.

## 저장 위치와 자격 증명

| 위치 | 사용할 수 있는 시점 | 저장 내용 |
| --- | --- | --- |
| 앱 DE(Device Encrypted) | 첫 잠금 해제 전부터 | 부팅 설정, 공개 키, 로그, 최소 검증 런타임 |
| 앱 CE(Credential Encrypted) | 첫 잠금 해제 후 | 자동 생성한 SSH 클라이언트 개인 키 |
| `/data/local/debian` | 사전 승인된 root를 통해 | Debian 전체 rootfs, 서비스, 사용자, 로컬 암호 hash |

SSH는 TCP 22에서 `debian` 사용자의 공개 키 인증만 허용합니다. SSH 비밀번호
인증과 SSH root 직접 로그인은 꺼져 있습니다. 앱에서 root 로컬 암호를 설정하면
인증된 `debian` 세션에서 `su root`로 전환할 수 있습니다.

PIN 입력 전에 사용할 데이터에는 재사용 auth key, API token, SSH 개인 키를 넣지
마세요.

## 빌드

가장 짧은 전체 빌드 방법은 다음과 같습니다.

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
./scripts/build-all.sh
```

기본값은 `make -j"$(nproc)"`이며 `DAWNSHELL_BUILD_JOBS`로 병렬 작업 수를 제한할
수 있습니다. debug APK는 `dist/dawnshell-app_v<version>+debug.apk`에 생성됩니다.

필요 패키지, Windows/MSYS2, 개별 검사, 서명, CI와 Release 묶음은
[빌드와 배포](docs/building.ko.md)를 참고하세요. 공개 debug 키는 제품용 서명 키가
아닙니다.

## 문서

### 사용자 문서

- [문서 홈](docs/README.ko.md)
- [설치 가이드](docs/installation.ko.md)
- [사용자 매뉴얼](docs/user-guide.ko.md)
- [문제 해결 가이드](docs/troubleshooting.ko.md)
- [쉬운 용어집](docs/glossary.ko.md)
- [FFmpeg 하드웨어 코덱 사용법](docs/ffmpeg-hardware-codec.ko.md)
- [FFmpeg MediaCodec 문법 호환성](docs/ffmpeg-mediacodec-compatibility.ko.md)
- [`gsmi` 가속기 상태 모니터](docs/gpu-status-tool.ko.md)

### 운영과 검증

- [보안 모델](docs/security.ko.md)
- [테스트 방법](docs/testing.ko.md)
- [개발 진행 상황](docs/progress.ko.md)

### 구조와 개발

- [아키텍처](docs/architecture.ko.md)
- [Debian rootfs 설치 과정](docs/rootfs-installation.ko.md)
- [Debian systemd와 SSH](docs/debian-systemd.ko.md)
- [하드웨어 코덱 worker 프로토콜](docs/hardware-codec-protocol.ko.md)
- [하드웨어 코덱 구현 결정 기록](docs/media-codec-bridge-plan.ko.md)
- [빌드와 배포](docs/building.ko.md)
- [내장 부트스트랩 런타임](bfu-runtime/README.ko.md)
- [Dropbear 조사 메모](bfu-runtime/dropbear/README.ko.md)
- [서드파티 고지](bfu-runtime/THIRD_PARTY_NOTICES.ko.md)
- [라이선스 묶음](LICENSES/README.md)
- [Android 의존성 고지](LICENSES/ANDROID_DEPENDENCIES.md)

## 라이선스

DawnShell 앱 코드는 [MIT License](LICENSE)로 배포합니다. 내장 도구와 라이브러리는
각 upstream 라이선스를 유지합니다. Release에는 [빌드와 배포](docs/building.ko.md)에
설명된 대응 소스, 라이선스, 빌드 정보와 SHA-256이 함께 포함됩니다.
