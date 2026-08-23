# Debian rootfs 설치 과정

[English](rootfs-installation.md) · [쉬운 용어집](glossary.ko.md)

rootfs(root file system)는 Debian의 `/`, `/etc`, `/usr`, `/var` 등이 들어 있는
전체 파일 구조입니다. DawnShell은 Debian 13 Trixie rootfs를
`/data/local/debian`에 설치합니다.

## 설치 전 조건

- Android 잠금이 해제되어 있어야 합니다.
- DawnShell에 root 권한이 있어야 합니다.
- 기기 ABI가 `armeabi-v7a`, `arm64-v8a`, `x86_64` 중 하나여야 합니다.
- 앱의 BFU 런타임 배치가 완료되어야 합니다.
- `/data/local/debian`에 기존의 정상 설치가 없어야 합니다.

ABI(Application Binary Interface)는 CPU에 맞는 실행 파일 규칙입니다.
[Google Android ABI 문서](https://developer.android.com/ndk/guides/abis)에서
자세히 확인할 수 있습니다.

## 내장 도구

앱은 각 ABI용 도구를 소스에서 빌드해 APK에 포함합니다.

- BusyBox: 기본 파일과 셸 명령을 제공합니다.
- `pkgdetails`: Debian 패키지 정보를 읽습니다.
- `gpgv`: Debian Release 전자서명을 확인합니다.
- Debian archive keyring: Debian 공식 공개 키를 제공합니다.
- namespace 런처: rootfs 설치와 systemd 실행 공간을 준비합니다.

소스 버전과 SHA-256은 `bfu-runtime/sources/SOURCES.lock`에 고정되어 있습니다.

## 설치 순서

1. 기기 ABI에 맞는 내장 런타임을 확인합니다.
2. 필요한 실행 파일과 설정을 앱 DE(Device Encrypted) 저장소에 배치합니다.
3. `/data/local/debian.installing` 임시 폴더를 만듭니다.
4. Debian Release 파일과 서명을 받습니다.
5. `gpgv`로 공식 Debian 서명을 확인합니다.
6. 패키지 목록과 각 패키지 SHA-256을 확인합니다.
7. Debian 기본 패키지를 임시 폴더에 풉니다.
8. `dpkg` 상태, 필수 파일, 소유권, 아키텍처를 검사합니다.
9. 모든 검사가 성공하면 `/data/local/debian`으로 원자적으로 이름을 바꿉니다.
10. ready marker를 기록합니다.

원자적 게시란 완성된 결과만 최종 경로에 한 번에 나타나게 하는 방식입니다.
중간에 실패한 불완전한 rootfs가 정상 설치처럼 보이는 일을 막습니다.

## 검증 항목

설치가 끝나기 전에 다음 내용을 확인합니다.

- Debian 아키텍처가 Android ABI와 일치합니다.
- `/bin/sh`, `dpkg`, 기본 라이브러리가 존재합니다.
- root 소유권과 파일 권한이 올바릅니다.
- 패키지 데이터베이스가 읽힙니다.
- `chroot` 안에서 기본 명령이 실행됩니다.

BusyBox는 `stat -c` 형식 출력을 지원해야 합니다. 최신 APK는 다운로드 전에 이
기능을 먼저 검사하므로 오래된 런타임으로 긴 설치를 시작하지 않습니다.

## 실패 처리

실패한 설치는 바로 삭제하지 않습니다. 다음 시도에서
`/data/local/debian.failed.<시간>`으로 옮겨 로그와 상태를 보존합니다.

자주 확인할 오류는 다음과 같습니다.

- 서명 검증 실패: 네트워크 중간 변조나 잘못된 keyring 가능성을 확인합니다.
- SHA-256 불일치: 손상된 다운로드를 다시 받습니다.
- `stat: invalid option -- c`: 최신 APK로 업데이트한 뒤 다시 시도합니다.
- 공간 부족: 내부 저장 공간을 확보합니다.
- 아키텍처 불일치: 기기 ABI와 선택된 Debian 아키텍처를 확인합니다.

서명이나 해시 오류를 무시하고 설치를 강제로 진행하지 마세요.

## 삭제

rootfs 삭제는 앱의 위험 구역에서만 수행합니다. 서버를 먼저 중지하고, 두 단계
확인과 `DELETE` 입력을 완료해야 합니다. 삭제 대상은 정확히
`/data/local/debian` 하나로 제한됩니다.

## 관련 문서

- [설치 가이드](installation.ko.md)
- [보안 모델](security.ko.md)
- [Debian systemd 구성](debian-systemd.ko.md)
