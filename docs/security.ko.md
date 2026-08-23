# DawnShell 보안 모델

[English](security.md) · [쉬운 용어집](glossary.ko.md)

DawnShell은 PIN 입력 전에도 root 권한으로 Debian과 네트워크 서비스를
시작합니다. 편리한 만큼 일반 Android 앱보다 강한 주의가 필요합니다.

## 지켜야 하는 원칙

1. Android의 CE(Credential Encrypted) 암호화를 우회하지 않습니다.
2. BFU(Before First Unlock)에 필요한 최소 정보만 DE(Device Encrypted)에 둡니다.
3. 비밀번호, API 토큰, 재사용 인증 키, SSH 개인 키를 DE에 저장하지 않습니다.
4. SSH는 공개 키 인증만 허용합니다.
5. root 명령은 고정된 동작과 경로만 사용합니다.
6. Debian root를 일반 가상 머신처럼 안전하게 격리됐다고 가정하지 않습니다.

Google도 Direct Boot에서는 꼭 필요한 데이터만 DE에 두고, 개인 정보는 CE에
보관하도록 안내합니다.

- [Google: Direct Boot 저장소 보안](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted)
- [AOSP: 파일 기반 암호화](https://source.android.com/docs/security/features/encryption/file-based)

## 위협 모델

다음 상황을 고려합니다.

- 잠금 화면을 풀지 못한 사람이 네트워크를 통해 SSH 접속을 시도합니다.
- 다른 Android 앱이 DawnShell의 파일이나 구성 요소에 접근하려고 합니다.
- 오래된 PID 파일이나 조작된 rootfs가 root helper를 속이려고 합니다.
- Docker 또는 VPN 설정이 Android 전체 네트워크를 바꾸려고 합니다.
- 로그나 클립보드를 통해 비밀번호 또는 개인 키가 유출됩니다.

커널, ROM 또는 Magisk 자체가 이미 손상된 상황은 앱만으로 완전히 방어할 수
없습니다.

## Android 앱 격리

DawnShell은 전용 UID(User Identifier)로 실행됩니다. export가 필요하지 않은
receiver와 service는 외부 앱에 공개하지 않습니다. Android의 UID와 SELinux
기반 격리는 [AOSP 앱 샌드박스 문서](https://source.android.com/docs/security/app-sandbox)에
설명되어 있습니다.

root 승인 화면에는 현재 UID에 연결된 패키지 목록을 보여 줍니다. 예상하지 못한
패키지가 표시되면 승인하지 마세요.

## DE와 CE

DE는 기기가 정상 부팅되면 PIN 입력 전에도 열립니다. 따라서 다음 정보만 둡니다.

- Direct Boot 활성화 여부
- 공개 SSH 키
- 비밀이 아닌 로그와 상태 표식
- 검증된 네이티브 실행 파일

CE는 첫 잠금 해제 후에 열립니다. 생성된 SSH 클라이언트 개인 키는 CE에만
저장합니다. 부팅 시에는 sentinel과 receipt를 이용해 앱 CE가 실제로 읽히지
않는지 확인합니다. 잠금 여부는
[`UserManager.isUserUnlocked()`](https://developer.android.com/reference/android/os/UserManager#isUserUnlocked())로
확인합니다.

일부 수정 ROM이 BFU에서 CE를 노출하면 기본 정책은 Debian 시작을 차단합니다.
예외 옵션은 위험을 사용자가 명시적으로 수락할 때만 사용합니다. 이 옵션은 CE를
다시 암호화하지 않습니다.

## root helper

앱은 자유로운 root 셸 명령을 만들지 않습니다. 검토된 helper에 operation ID와
검증된 값만 전달합니다.

- rootfs 대상은 `/data/local/debian`으로 고정합니다.
- 삭제 대상은 정규화한 뒤 정확히 다시 비교합니다.
- shell metacharacter가 포함된 사용자 값을 명령 문자열에 넣지 않습니다.
- Android 호스트 `/data`를 remount하지 않습니다.
- supervisor를 중지할 때 PID뿐 아니라 UID, 실행 파일, namespace를 확인합니다.

## SSH

기본 SSH 정책은 다음과 같습니다.

```text
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
```

`debian` 계정의 공개 키만 `authorized_keys`에 설치합니다. root 비밀번호를 앱에서
설정해도 SSH 비밀번호 인증은 켜지지 않습니다. root 전환은 로그인 뒤 `su root`로
수행합니다.

개인 키 내보내기는 사용자가 버튼을 눌렀을 때만 실행합니다. 클립보드 명령에는
전체 개인 키가 들어 있으므로 파일 내보내기를 권장합니다. 클립보드 항목은
가능하면 120초 뒤 지우지만 다른 앱이 그전에 읽을 가능성은 남아 있습니다.

## 비밀번호

앱은 비밀번호를 `chpasswd`의 표준 입력으로만 전달합니다. 다음 위치에는 저장하지
않습니다.

- Android SharedPreferences
- DE 저장소
- 로그
- 명령행 인수

비밀번호 입력이 끝나면 메모리의 임시 문자 배열을 가능한 범위에서 지웁니다.

## 네트워크와 Docker

Debian은 Android network namespace를 공유합니다. 이 구조는 빠르지만 Debian의
root 네트워크 변경이 Android 전체에 영향을 줄 수 있다는 뜻입니다.

기본 Docker 정책은 bridge, iptables, ip6tables, IP forwarding, masquerading을
끄는 host-network-only 모드입니다. bridge 옵션은 Wi-Fi, 모바일 데이터, USB
Ethernet, VPN, Tailscale, SSH를 끊을 수 있으므로 별도 복구 경로가 있을 때만
사용해 주세요.

Docker 호스트 IPC 호환 옵션은 기본적으로 꺼져 있습니다. 관리형 CLI 래퍼가
컨테이너 생성에 `--ipc=host`를 추가하므로 컨테이너가 Android 및 Debian과
공유하는 IPC 객체를 보거나 변경할 수 있습니다. private IPC/mqueue 경로가
고장 난 커널에서만 사용하고 신뢰하지 않는 컨테이너는 실행하지 마세요. private
IPC가 필요하고 커널이 지원한다면 `/usr/bin/docker`로 래퍼를 우회할 수 있습니다.

## 호스트 USB

raw 호스트 USB 접근은 명시적으로 켜야 합니다. 기본 정책은 Debian mount
namespace에서 `/dev/bus/usb`를 가리고 DawnShell 전용 devices 정책에서 USB 문자
장치 major 189를 거부합니다. 직접 모드는 Debian에 대해서만 이 두 제한을
해제하고 Android 커널 드라이버 연결은 유지합니다. 독점 모드는 명시한 `VID:PID`
허용 목록에 맞는 interface까지 unbind합니다. cgroup 권한은 계속 위임된 범위에
있지만 이 unbind는 호스트 전체의 하드웨어 상태를 바꿉니다. 정상 종료 때 모두
복원을 시도하지만 SIGKILL, 커널 오류 또는 전원 손실 시 복원하지 못할 수 있으므로
장치를 뽑거나 재부팅해야 합니다. 두 모드 모두 SELinux 제한은 유지됩니다.

USB 장치는 능동적인 신뢰 경계입니다. 펌웨어 프로그래머, 입력 장치, 네트워크
어댑터와 이동식 저장장치는 하드웨어나 호스트 상태를 바꿀 수 있습니다. 신뢰하지
않는 장치를 노출하거나 Docker `--privileged`를 사용하지 말고, 같은 이동식
파일시스템을 Android와 Debian에서 동시에 마운트하지 마세요. 휴대전화 내부
USB/gadget controller를 독점 허용 목록에 넣지 마세요.

## 하드웨어 영상 코덱

코덱 브리지는 기본적으로 꺼져 있으며 외부 TCP 포트를 열지 않습니다. secure/DRM
코덱은 목록과 생성 대상에서 제외하고 소프트웨어 코덱으로 자동 전환하지 않습니다.
코덱 프로세스는 앱의 별도 Android 프로세스에 격리됩니다. DE에는 코덱 이름,
capability와 오류만 저장하며 영상 frame, bitstream, 파일 경로와 인증 정보는
저장하지 않습니다. 신뢰하지 않는 영상의 자동 처리는 실제 frame protocol이
구현된 뒤에도 기본 비활성 상태를 유지해야 합니다.

## 로그

로그에는 다음 정보를 남기지 않습니다.

- 비밀번호
- SSH 개인 키 본문
- API 토큰과 인증 키
- `authorized_keys` 전체 내용

오류 보고 전에 복사한 로그에 개인 정보가 추가되지 않았는지 확인해 주세요.

## 업데이트와 서명

Android는 모든 APK(Android Package)를 서명된 상태로 설치합니다. 같은 앱을
데이터를 유지하며 업데이트하려면 같은 앱 서명 키가 필요합니다.
[Google 앱 서명 안내](https://developer.android.com/studio/publish/app-signing)를
참고해 주세요.

정식 Release의 `SHA256SUMS`를 확인하고, 공개 debug 키로 만든 APK를 제품용으로
사용하지 마세요.

## 운영 권장 사항

- BFU 전용 SSH 키를 다른 서버에서 재사용하지 않습니다.
- 불필요한 토큰과 자격 증명을 Debian에 저장하지 않습니다.
- Magisk 승인은 DawnShell 패키지에만 영구 허용합니다.
- rootfs 삭제 전에 데이터와 SSH 키를 별도로 백업합니다.
- Docker bridge와 root 명령은 로컬 복구 수단을 준비한 뒤 사용합니다.
- 보안 문제가 의심되면 SSH 키를 교체하고 systemd + SSH 구성을 다시 실행합니다.
