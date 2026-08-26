# DawnShell 문서

[English](README.md) · [프로젝트 홈](../README.ko.md) · [최신 릴리스](https://github.com/aroxu/dawnshell/releases/latest)

DawnShell을 처음 설치하는 사용자부터 내부 구조를 검토하는 개발자까지 필요한
문서를 한곳에서 찾을 수 있는 문서 홈입니다. 처음 사용한다면 아래 **처음 설치하는
순서**만 따라가면 됩니다.

> **먼저 확인하세요**
>
> DawnShell은 root 권한이 필수이며 Debian과 Android가 같은 커널과 네트워크를
> 공유합니다. 일반 가상 머신처럼 완전히 격리된 환경이 아닙니다. Docker bridge,
> USB 독점 패스스루, CE 예외 허용은 복구 수단을 준비한 뒤에만 사용하세요.

## 처음 설치하는 순서

| 순서 | 할 일 | 완료 확인 |
| ---: | --- | --- |
| 1 | [설치 가이드](installation.ko.md)에 따라 APK와 root 권한을 준비합니다. | 앱의 root 검사에 `uid=0`이 표시됩니다. |
| 2 | 앱에서 BFU 설정을 저장하고 Debian 13을 설치합니다. | Debian 설치 로그가 `INSTALL_SUCCEEDED`로 끝납니다. |
| 3 | systemd와 SSH를 구성합니다. | 구성 로그가 `CONFIGURE_SUCCEEDED`로 끝납니다. |
| 4 | SSH 개인 키를 내보내고 접속합니다. | `debian` 사용자로 로그인됩니다. |
| 5 | 재부팅하고 잠금을 풀지 않은 상태에서 접속합니다. | BFU에서 SSH가 되고, 잠금을 풀어도 연결이 유지됩니다. |

일상적인 시작·중지, 계정, 네트워크 사용법은 [사용자 매뉴얼](user-guide.ko.md),
오류가 생겼을 때 수집할 정보는 [문제 해결 가이드](troubleshooting.ko.md)에 있습니다.

## 하려는 일로 찾기

| 하려는 일 | 문서 |
| --- | --- |
| 처음 설치하고 BFU SSH를 확인하고 싶습니다 | [설치 가이드](installation.ko.md) |
| 앱의 모든 버튼과 설정을 알고 싶습니다 | [사용자 매뉴얼](user-guide.ko.md) |
| 오류 메시지별 원인과 확인 명령이 필요합니다 | [문제 해결 가이드](troubleshooting.ko.md) |
| 낯선 약어와 Linux 용어를 확인하고 싶습니다 | [쉬운 용어집](glossary.ko.md) |
| USB 장치를 Debian에서 사용하고 싶습니다 | [사용자 매뉴얼의 USB 절](user-guide.ko.md#6-usb-공유와-패스스루) |
| Docker를 안전하게 시작하고 싶습니다 | [사용자 매뉴얼의 Docker 절](user-guide.ko.md#9-docker) |
| FFmpeg에서 H.264/HEVC 하드웨어 가속을 쓰고 싶습니다 | [FFmpeg 하드웨어 코덱 사용법](ffmpeg-hardware-codec.ko.md) |
| `-hwaccel mediacodec` 문법의 동작 범위를 알고 싶습니다 | [FFmpeg MediaCodec 호환성](ffmpeg-mediacodec-compatibility.ko.md) |
| `gsmi` 출력이 무엇을 뜻하는지 알고 싶습니다 | [가속기 상태 모니터](gpu-status-tool.ko.md) |
| 앱을 직접 빌드하거나 Release를 만들고 싶습니다 | [빌드와 배포](building.ko.md) |
| 실기기에서 전체 기능을 검증하고 싶습니다 | [테스트 방법](testing.ko.md) |

## 사용자 문서

| 문서 | 내용 |
| --- | --- |
| [설치 가이드](installation.ko.md) | 다운로드 검증, root 승인, Debian 설치, SSH 키 내보내기, 첫 BFU 시험 |
| [사용자 매뉴얼](user-guide.ko.md) | 앱 화면 순서, 서버 제어, SSH, 계정, USB, 영상 가속, Docker, 로그, 삭제 |
| [문제 해결 가이드](troubleshooting.ko.md) | 부팅·root·설치·SSH·Docker·USB·코덱 오류별 점검 순서 |
| [쉬운 용어집](glossary.ko.md) | BFU, AFU, DE, CE, rootfs, cgroup, namespace 등 |
| [FFmpeg 하드웨어 코덱 사용법](ffmpeg-hardware-codec.ko.md) | 파일 변환, 오디오 복사, HLS, USB 웹캠, 자동 래퍼, 원시 파이프라인 |
| [FFmpeg MediaCodec 호환성](ffmpeg-mediacodec-compatibility.ko.md) | 순정 FFmpeg 문법과 DawnShell 구현의 차이, 지원 옵션, 폴백 규칙 |
| [`gsmi` 가속기 상태 모니터](gpu-status-tool.ko.md) | 3D GPU와 영상 코덱 엔진을 구분해 읽는 방법 |

## 운영·검증 문서

| 문서 | 내용 |
| --- | --- |
| [보안 모델](security.ko.md) | 저장소, root, SSH 키, Docker, USB, 코덱의 신뢰 경계 |
| [테스트 방법](testing.ko.md) | BFU/AFU, 5회 부팅, 네트워크, USB, Docker, 코덱 검증 절차 |
| [개발 진행 상황](progress.ko.md) | 완료 기능, 실기기에서 확인한 항목, 남은 검증 |

## 내부 구조와 개발 문서

| 문서 | 내용 |
| --- | --- |
| [아키텍처](architecture.ko.md) | 부팅 흐름, DE/CE/rootfs, namespace, cgroup, 중복 실행 방지 |
| [Debian rootfs 설치 과정](rootfs-installation.ko.md) | 내장 부트스트랩 도구, 서명·해시 검증, 원자적 게시, 실패 보존 |
| [Debian systemd와 SSH](debian-systemd.ko.md) | 런타임 mount, PID 1, 네트워크, SSH 정책, 종료와 재시작 |
| [하드웨어 코덱 worker 프로토콜](hardware-codec-protocol.ko.md) | `memfd`/`eventfd`, 메시지 형식, 하드웨어 선택, 제한값 |
| [하드웨어 코덱 구현 결정 기록](media-codec-bridge-plan.ko.md) | 최종 구조를 선택한 이유와 비목표를 기록한 설계 결정 문서 |
| [빌드와 배포](building.ko.md) | 로컬 빌드, 병렬 작업 수, CI, 서명, Release 구성 |

## 라이선스와 고지

| 문서 | 내용 |
| --- | --- |
| [라이선스 묶음](../LICENSES/README.md) | APK에 포함되는 라이선스와 Release 배포 조건 |
| [Android 의존성 고지](../LICENSES/ANDROID_DEPENDENCIES.md) | Gradle로 APK에 포함되는 Android 라이브러리 고지 |
| [내장 런타임 고지](../bfu-runtime/THIRD_PARTY_NOTICES.ko.md) | native 도구, Debian 자료와 대응 소스 안내 |

## 문서에서 사용하는 표기

- `PHONE_IP`는 휴대전화의 실제 IP 주소로 바꿉니다.
- `<version>`은 설치할 Release 버전으로 바꿉니다.
- `sudo`가 붙은 명령은 Debian 안에서 root 권한이 필요합니다.
- **굵은 글씨**는 앱에 표시되는 버튼이나 설정 이름입니다.
- `BFU`는 재부팅 후 첫 잠금 해제 전, `AFU`는 첫 잠금 해제 후입니다.

명령을 복사할 때 프롬프트 문자(`$`, `#`)는 포함하지 않습니다. 줄 끝의 `\`는
명령이 다음 줄로 이어진다는 뜻입니다.

## 오류를 공유할 때

1. [문제 해결 가이드](troubleshooting.ko.md)의 해당 절을 먼저 실행합니다.
2. 앱의 **실시간 로그**에서 관련 로그를 열고 전체 내용을 복사합니다.
3. Android 버전, CPU ABI, DawnShell 버전, 사용한 설정과 재현 순서를 함께 적습니다.
4. 비밀번호, SSH 개인 키, API 토큰, Tailscale 인증 키는 반드시 지웁니다.
