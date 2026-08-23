# DawnShell 설치 가이드

[English](installation.md)

[프로젝트 홈](../README.ko.md) · [사용자 매뉴얼](user-guide.ko.md) ·
[쉬운 용어집](glossary.ko.md) · [최신 릴리스](https://github.com/aroxu/dawnshell/releases/latest)

이 가이드는 GitHub Release에 게시된 정식 APK(Android Package, Android 설치
파일)를 기준으로 설명합니다. 처음 설치하셔도 순서대로 진행하면 됩니다.

## 1. 시작하기 전에 확인합니다

다음 조건이 필요합니다.

- Android 7.0(API 24) 이상을 사용합니다.
- FBE(File-Based Encryption, 파일 기반 암호화)가 켜져 있습니다.
- 기기 CPU가 `armeabi-v7a`, `arm64-v8a`, `x86_64` 중 하나입니다.
- Magisk 또는 호환되는 `su`가 설치되어 있습니다.
- Debian을 받을 인터넷 연결과 충분한 내부 저장 공간이 있습니다.
- BFU(Before First Unlock, 최초 잠금 해제 전) 원격 접속이 필요하다면 ROM이
  재부팅 후 Wi-Fi 또는 다른 네트워크를 자동으로 연결해야 합니다.

용어가 낯설다면 [쉬운 용어집](glossary.ko.md)을 먼저 확인해 주세요. Android의
공식 Direct Boot 요구 사항은 [Google 문서](https://developer.android.com/privacy-and-security/direct-boot)에서
확인할 수 있습니다.

DawnShell은 Debian을 시작할 때 root 권한이 필요합니다. ADB(Android Debug
Bridge)는 필수가 아니며 문제를 확인할 때만 선택적으로 사용합니다.
[Google ADB 안내](https://developer.android.com/tools/adb)도 참고할 수 있습니다.

다른 SSH 서버가 이미 TCP 22 포트를 사용한다면 먼저 포트 충돌을 해결합니다.
Samsung 등 제조사 ROM에서는 DawnShell을 배터리 최적화, 절전, 자동 시작 제한
대상에서 제외하는 것을 권장합니다.

## 2. Release 파일을 받고 확인합니다

1. [DawnShell Releases](https://github.com/aroxu/dawnshell/releases)에서 최신
   정식 버전을 엽니다.
2. 다음 두 파일을 같은 폴더에 받습니다.

```text
dawnshell-<version>.apk
SHA256SUMS
```

`SHA256SUMS`는 다운로드한 파일이 배포 중에 손상되거나 바뀌지 않았는지 확인하는
목록입니다.

Linux 또는 macOS의 셸에서는 다음과 같이 확인합니다.

```sh
sha256sum -c SHA256SUMS
```

macOS 기본 명령만 사용한다면 다음 명령을 사용합니다.

```sh
shasum -a 256 -c SHA256SUMS
```

Windows PowerShell에서는 다음 두 결과를 비교합니다.

```powershell
Get-FileHash .\dawnshell-0.2.0.apk -Algorithm SHA256
Get-Content .\SHA256SUMS
```

파일명은 받은 버전에 맞게 바꿉니다. 값이 다르면 설치하지 말고 다시 받습니다.

GitHub Actions의 일반 artifact는 공개 debug 키로 서명된 시험용 파일일 수
있습니다. 일반 사용자는 태그에서 만들어진 정식 Release APK를 사용해 주세요.
Android 앱 서명이 궁금하다면
[Google 앱 서명 문서](https://developer.android.com/studio/publish/app-signing)를 참고합니다.

## 3. APK를 설치합니다

휴대폰에서 APK를 열고, 해당 브라우저 또는 파일 앱에 “알 수 없는 앱 설치”를
일시적으로 허용합니다. 설치가 끝나면 필요하지 않은 허용을 다시 꺼도 됩니다.

ADB를 이미 사용하고 있다면 다음 방법도 가능합니다.

```sh
adb install -r dawnshell-<version>.apk
```

같은 서명 키로 만든 업데이트는 보통 앱 데이터와 설정을 유지합니다. 다른 키로
서명된 APK는 기존 앱 위에 설치되지 않습니다. 앱을 제거하면 앱의 DE(Device
Encrypted)와 CE(Credential Encrypted) 데이터, 생성된 SSH 클라이언트 개인 키가
삭제됩니다. `/data/local/debian`은 앱 제거만으로 자동 삭제되지 않습니다.

## 4. Magisk root 권한을 영구 허용합니다

Android 잠금을 해제한 상태에서 DawnShell을 엽니다.

1. **Magisk 루트 권한 요청 / 확인**을 누릅니다.
2. 승인 창에 DawnShell 패키지 `me.aroxu.dawnshell`이 표시되는지 확인합니다.
3. Magisk에서 **영구 허용** 또는 **항상 허용**을 선택합니다.
4. 앱의 결과에서 `exit=0`, `root=true`, `uid=0`을 확인합니다.

BFU에서는 승인 화면을 띄울 수 없으므로 일회성 승인은 충분하지 않습니다.
Magisk 관리자에서도 DawnShell 권한이 영구 허용인지 다시 확인해 주세요.

## 5. Direct Boot 설정을 저장합니다

처음에는 다음 값을 권장합니다.

- **다이렉트 부트 Debian 부트스트랩 활성화**: 켭니다.
- **CE 저장소를 읽을 수 있는 BFU 환경 허용**: 끕니다.
- cgroup: **자동: cgroup v2 → v1 전환(권장)**을 선택합니다.
- Docker 네트워크: **안전한 호스트 네트워크만 사용(권장)**을 선택합니다.

그다음 **BFU 설정 저장 및 런타임 배치**를 누릅니다. 이 버튼은 설정과 기기
CPU에 맞는 실행 파일을 DE 저장소에 준비합니다. “설정이 변경되었습니다”라는
표시가 남아 있다면 재부팅 전에 한 번 더 저장합니다.

CE 읽기 허용 옵션은 일반적으로 켜지 않습니다. Google의 Direct Boot 설계에서는
사용자가 잠금을 풀기 전 CE가 닫혀 있어야 합니다. 자세한 차이는
[Google DE/CE 설명](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted)에서
확인할 수 있습니다.

## 6. Debian 13을 설치합니다

1. **Debian 13 Trixie rootfs 설치**를 누릅니다.
2. 확인 창에서 설치를 승인합니다.
3. **로그 → Debian 설치**를 엽니다.
4. 상태가 `SUCCEEDED`가 되고 마지막에 `INSTALL_SUCCEEDED`가 표시될 때까지
   기다립니다.

rootfs(root file system)는 Debian의 전체 파일 구조입니다. 설치 프로그램은
Debian Release 서명과 패키지 해시를 확인한 뒤 임시 위치에 설치합니다. 검증이
끝난 결과만 `/data/local/debian`에 게시합니다.

실패하면 로그를 먼저 복사합니다. 중단된 설치 폴더는 다음 시도 때
`/data/local/debian.failed.<시간>`으로 옮겨져 진단 자료로 보존됩니다.

## 7. systemd와 SSH를 구성합니다

Debian 설치가 성공한 뒤 다음 순서로 진행합니다.

1. 생성된 Ed25519 공개 키가 화면에 표시되는지 확인합니다.
2. **Debian 13 systemd + SSH 구성**을 누릅니다.
3. **로그 → 시스템 구성**을 엽니다.
4. 상태가 `SUCCEEDED`, 마지막 결과가 `CONFIGURE_SUCCEEDED`인지 확인합니다.
5. **상태**를 눌러 systemd, D-Bus, SSH와 TCP 22가 정상인지 확인합니다.

SSH(Secure Shell)는 암호화된 원격 셸 연결 방식입니다. 기본 사용자는 `debian`,
기본 포트는 TCP 22입니다. 비밀번호 인증과 SSH root 직접 로그인은 꺼져 있으며,
앱이 생성한 공개 키만 허용됩니다.

## 8. SSH 개인 키를 내보냅니다

외부 PC에서 접속하려면 **SSH 개인 키 파일 내보내기**를 누릅니다. 저장한 파일은
안전하게 PC로 옮기고 소유자만 읽을 수 있게 설정합니다.

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

같은 휴대폰의 신뢰할 수 있는 로컬 셸에서 접속하려면 다음 방법을 사용합니다.

1. **로컬 셸용 개인 키 가져오기 명령 복사**를 누릅니다.
2. 경고를 확인하고 복사한 명령을 본인의 로컬 셸에 즉시 붙여 넣습니다.
3. **SSH 접속 명령 복사**를 누르고 복사한 명령을 실행합니다.

첫 번째 명령에는 개인 키 전체가 포함됩니다. 클립보드는 120초 뒤 자동으로
지워지지만, 파일 내보내기가 더 안전합니다.

## 9. BFU 부팅을 시험합니다

설정이 모두 성공한 뒤 휴대폰을 재부팅합니다. PIN, 패턴 또는 비밀번호는 아직
입력하지 않습니다. 다른 기기에서 휴대폰 주소로 접속합니다.

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

접속 후 다음 명령을 확인합니다.

```sh
id
cat /proc/1/comm
systemctl is-active ssh.service
ip addr
uptime
```

`/proc/1/comm`은 `systemd`, SSH 서비스는 `active`로 표시되어야 합니다. 이후
Android 잠금을 풀고 기존 SSH 연결과 Debian PID(Process Identifier) 1이 그대로
유지되는지 확인합니다.

## 10. 업데이트합니다

1. 새 Release의 안내와 `SHA256SUMS`를 확인합니다.
2. 같은 서명 키의 APK를 기존 앱 위에 설치합니다.
3. 잠금을 해제한 상태에서 DawnShell을 한 번 엽니다.
4. **BFU 설정 저장 및 런타임 배치**를 다시 누릅니다.
5. 상태를 확인하고 계획된 시점에 서버를 재시작하거나 BFU 부팅을 시험합니다.

업데이트 전에 SSH 개인 키를 별도 안전한 위치에 보관하는 것을 권장합니다.

## 다음 문서

- 일상적인 사용 방법: [사용자 매뉴얼](user-guide.ko.md)
- 약어와 기술 용어: [쉬운 용어집](glossary.ko.md)
- 보안 전제와 위험: [보안 모델](security.ko.md)
- 자세한 설치 내부 동작: [rootfs 설치 문서](rootfs-installation.ko.md)
- 전체 실기기 검증: [테스트 방법](testing.ko.md)
