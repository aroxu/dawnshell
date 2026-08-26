# DawnShell 쉬운 용어집

[English](glossary.md)

[문서 홈](README.ko.md) · [설치 가이드](installation.ko.md) ·
[사용자 매뉴얼](user-guide.ko.md)

처음 보는 약어가 많아도 걱정하지 않으셔도 됩니다. 이 문서는 DawnShell에서
자주 사용하는 말을 쉬운 표현으로 설명합니다. Android 동작과 직접 관련된
항목에는 Google 또는 AOSP(Android Open Source Project) 공식 문서를 연결했습니다.

## Android 부팅과 저장소

### BFU — Before First Unlock

기기를 재부팅한 뒤 PIN, 패턴, 비밀번호를 **처음 입력하기 전** 상태입니다.
DawnShell은 이때 Debian과 SSH를 시작하는 것이 핵심 목표입니다.

### AFU — After First Unlock

재부팅 후 사용자가 잠금을 **한 번 이상 해제한 뒤** 상태입니다. 화면을 다시
잠가도 재부팅 전까지는 AFU 상태가 유지됩니다.

### Direct Boot

사용자가 처음 잠금을 풀기 전에도 일부 앱 기능을 안전하게 실행할 수 있도록
Android 7.0에서 추가된 기능입니다. 앱은 `directBootAware` 구성 요소와
`LOCKED_BOOT_COMPLETED` 알림을 사용합니다.

- [Google: Direct Boot 지원 방법](https://developer.android.com/privacy-and-security/direct-boot)
- [Google: Intent 부팅 알림 API](https://developer.android.com/reference/android/content/Intent#ACTION_LOCKED_BOOT_COMPLETED)

### FBE — File-Based Encryption

한국어로는 **파일 기반 암호화**입니다. 저장소 전체를 하나의 키로 여는 대신,
파일을 용도에 맞는 키로 보호합니다. 이 구조 덕분에 Android는 DE와 CE 저장소를
구분할 수 있습니다.

- [AOSP: 파일 기반 암호화](https://source.android.com/docs/security/features/encryption/file-based)

### DE — Device Encrypted storage

한국어로는 **기기 암호화 저장소**입니다. 기기가 정상적으로 부팅되면 PIN 입력
전에도 사용할 수 있습니다. DawnShell은 BFU에 꼭 필요한 설정, 공개 키, 로그만
앱 전용 DE 영역에 저장합니다. 비밀번호와 개인 키를 두는 곳이 아닙니다.

### CE — Credential Encrypted storage

한국어로는 **사용자 인증 정보 암호화 저장소**입니다. 재부팅 후 PIN, 패턴 또는
비밀번호를 처음 입력해야 열립니다. DawnShell이 생성한 SSH 클라이언트 개인 키는
CE에 보관합니다.

- [Google: DE와 CE 저장소의 차이](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted)
- [Google: Device Protected Storage Context API](https://developer.android.com/reference/android/content/Context#createDeviceProtectedStorageContext())
- [Google: 사용자 잠금 해제 상태 확인](https://developer.android.com/reference/android/os/UserManager#isUserUnlocked())

### `LOCKED_BOOT_COMPLETED`

Android가 부팅을 마쳤지만 사용자가 아직 처음 잠금을 풀지 않았을 때 보내는
알림입니다. DawnShell은 이 알림을 받아 BFU 시작 절차를 실행합니다.

### `USER_UNLOCKED`

재부팅 후 사용자가 처음 잠금을 풀었을 때 보내는 알림입니다. DawnShell은 이
이벤트를 기록하지만, 이미 실행 중인 Debian을 중지하지 않습니다.

## 앱과 빌드

### AOSP — Android Open Source Project

Android 운영체제의 공개 소스 프로젝트입니다. `source.android.com` 문서는 Android
플랫폼 내부 구조와 보안을 설명하는 Google의 공식 자료입니다.

### APK — Android Package

Android 기기에 직접 설치하는 앱 파일입니다. 확장자는 `.apk`입니다.

- [Google: Android 앱과 APK 기본 구조](https://developer.android.com/guide/components/fundamentals)

### API — Application Programming Interface

앱이 Android 기능을 호출할 때 사용하는 약속입니다. `API 24`는 Android 7.0의
플랫폼 기능 수준을 뜻합니다.

### CPU — Central Processing Unit

기기의 명령을 실행하는 중앙 처리 장치입니다. ARM과 x86은 서로 다른 CPU 명령어
계열입니다. ARM64는 64비트 ARM을 뜻하며, AMD는 x86_64 프로세서를 만드는 회사
중 하나입니다.

### ABI — Application Binary Interface

CPU 종류에 맞는 네이티브 실행 파일 규칙입니다. DawnShell은 다음 세 가지를
지원합니다.

| Android ABI | 쉬운 설명 | Debian 이름 |
| --- | --- | --- |
| `armeabi-v7a` | 32비트 ARM | `armhf` |
| `arm64-v8a` | 64비트 ARM | `arm64` |
| `x86_64` | 64비트 Intel/AMD | `amd64` |

- [Google: Android ABI 안내](https://developer.android.com/ndk/guides/abis)

### ADB — Android Debug Bridge

PC에서 Android 기기에 명령을 보내고 로그를 확인하는 개발 도구입니다.
DawnShell 설치와 BFU 동작에 필수 권한은 아니며, 문제를 확인할 때 선택적으로
사용합니다.

- [Google: ADB 사용 안내](https://developer.android.com/tools/adb)
- [Google: 실제 기기 연결 방법](https://developer.android.com/studio/run/device)

### UID — User Identifier

Linux와 Android가 앱이나 사용자를 구분하는 숫자입니다. Android는 앱마다 별도
UID를 할당해 다른 앱의 파일을 기본적으로 읽지 못하게 합니다.

- [AOSP: Android 애플리케이션 샌드박스](https://source.android.com/docs/security/app-sandbox)

### APK 서명

APK를 만든 주체와 업데이트의 연속성을 확인하는 전자서명입니다. 같은 앱을
데이터를 유지한 채 업데이트하려면 보통 이전 버전과 같은 키로 서명해야 합니다.

- [Google: Android 앱 서명](https://developer.android.com/studio/publish/app-signing)

### SDK / NDK — Software Development Kit / Native Development Kit

SDK는 Android 앱과 API를 빌드하는 개발 도구 모음입니다. NDK는 C/C++ 네이티브
코드를 Android ABI용으로 빌드하는 도구 모음입니다.

- [Google: Android SDK 설치](https://developer.android.com/studio/intro/update#sdk-manager)
- [Google: Android NDK 시작하기](https://developer.android.com/ndk/guides)

### JDK — Java Development Kit

Java와 Android Gradle 빌드에 필요한 컴파일러와 실행 도구 모음입니다. DawnShell
로컬 빌드는 JDK 17을 사용합니다.

### PIE — Position-Independent Executable

메모리의 고정 주소에 의존하지 않도록 만든 실행 파일입니다. Android의 주소
공간 무작위화 보안 기능과 함께 사용됩니다.

### SHA-256 — Secure Hash Algorithm 256-bit

파일 내용으로 256비트 확인값을 만드는 해시 알고리즘입니다. 다운로드한 APK와
소스가 배포자가 제공한 파일과 같은지 확인할 때 사용합니다. 해시는 암호화나
전자서명 자체가 아닙니다.

### UI — User Interface

버튼, 화면, 메뉴처럼 사용자가 앱을 조작하는 부분입니다.

### URL — Uniform Resource Locator

웹 문서나 다운로드 파일의 인터넷 주소입니다.

### ROM — Read-Only Memory

원래는 읽기 전용 메모리라는 뜻입니다. Android 사용자들은 제조사 또는 커스텀
Android 운영체제 이미지를 흔히 ROM이라고 부릅니다.

### MSYS2

Windows에서 Bash, GNU make와 여러 Unix 계열 빌드 도구를 사용할 수 있게 하는
개발 환경입니다.

### GNU / GPL / LGPL / MIT

GNU는 자유 소프트웨어 프로젝트 이름입니다. GPL(GNU General Public License)과
LGPL(GNU Lesser General Public License)은 소스 제공과 재배포 조건을 정한
오픈소스 라이선스입니다. MIT는 비교적 간결하고 허용 범위가 넓은 오픈소스
라이선스입니다. DawnShell 앱 코드는 MIT이고, 내장 도구는 각 원래 라이선스를
유지합니다.

## Debian과 원격 접속

### rootfs — Root File System

Debian의 `/`, `/etc`, `/usr`, `/var` 등이 들어 있는 전체 파일 구조입니다.
DawnShell은 이를 `/data/local/debian`에 설치합니다.

### chroot — Change Root

프로세스가 바라보는 `/` 디렉터리를 Debian rootfs로 바꾸는 Linux 기능입니다.
가상 머신이 아니며 Android 커널은 그대로 공유합니다.

### PID — Process Identifier

실행 중인 프로세스를 구분하는 번호입니다. DawnShell이 만든 격리 공간에서는
Debian의 `systemd`가 PID 1로 보입니다.

### systemd

Debian 부팅과 서비스를 관리하는 프로그램입니다. SSH 서버 같은 서비스를
시작하고 상태를 확인합니다.

### SSH — Secure Shell

암호화된 네트워크 연결로 원격 셸을 사용하는 표준 프로토콜입니다. DawnShell은
비밀번호 대신 공개 키 인증만 허용합니다.

### OpenSSH

SSH 프로토콜을 구현한 프로그램 모음입니다. 서버 프로그램은 `sshd`, 접속
프로그램은 `ssh`입니다.

### D-Bus — Desktop Bus

Linux 프로그램과 서비스가 서로 메시지를 주고받는 통신 체계입니다. systemd가
여러 관리 명령을 처리할 때 사용합니다.

### container — 컨테이너

같은 Linux 커널을 공유하면서 파일, 프로세스, 자원 보기를 분리한 실행 환경입니다.
가상 머신과 달리 자체 커널이 없습니다. DawnShell의 Debian도 Android 커널을
공유하며, Debian 안의 Docker 컨테이너는 그 커널을 한 번 더 공유합니다.

### Docker

Linux 컨테이너를 만들고 실행하는 도구입니다. DawnShell에서는 Android 네트워크와
커널을 공유하므로 일반 서버보다 bridge, IPC, cgroup 설정의 영향 범위가 큽니다.

### FFmpeg

영상·음성 파일과 stream을 읽고 변환하고 저장하는 명령행 도구입니다. DawnShell은
Debian FFmpeg의 container 처리 기능과 Android MediaCodec을 연결합니다.

### AVC / H.264, HEVC / H.265

영상 압축 표준입니다. AVC와 H.264는 같은 표준을, HEVC와 H.265도 같은 표준을
가리키는 다른 이름입니다.

### MediaCodec

Android가 하드웨어 또는 소프트웨어 영상 코덱을 사용하는 API입니다. DawnShell은
소프트웨어 코덱을 하드웨어 성공으로 인정하지 않고 AVC/HEVC 작업만 연결합니다.

### I420 / YUV_420

색 밝기와 색차를 나눠 저장하는 raw 영상 형식입니다. 압축되지 않아 파일이 매우
크며, DawnShell의 ByteBuffer decode/encode 중간 형식으로 사용됩니다.

### VPU — Video Processing Unit

H.264/HEVC 인코딩과 디코딩을 담당하는 전용 영상 엔진의 일반적인 이름입니다.
제조사에 따라 MFC, Venus, Vcodec처럼 부릅니다. 3D GPU와 다른 장치이므로 VPU가
동작하는 동안 GPU 사용률이 0%일 수 있습니다.

### sysfs

Linux 커널의 장치와 driver 상태를 파일처럼 보여 주는 `/sys` 가상 파일시스템입니다.
`gsmi`와 USB 진단 명령이 여기서 가능한 정보를 읽습니다.

## 커널과 네트워크

### TCP / IP — Transmission Control Protocol / Internet Protocol

IP는 네트워크에서 기기 주소와 패킷 전달을 다룹니다. TCP는 그 위에서 순서와
전송 성공을 확인하는 연결을 제공합니다. “TCP 22”는 SSH가 기본적으로 기다리는
포트 번호를 뜻합니다.

### VPN — Virtual Private Network

공용 네트워크 위에 암호화되거나 분리된 가상 네트워크 연결을 만드는 기술입니다.
Tailscale도 VPN 방식의 연결을 제공합니다.

### USB — Universal Serial Bus

휴대폰과 PC, Ethernet 어댑터 같은 장치를 연결하는 표준입니다. USB Ethernet은
USB로 연결한 유선 네트워크 장치를 뜻합니다.

### NIC — Network Interface Controller

Wi-Fi, 모바일 데이터, USB Ethernet처럼 네트워크에 연결되는 장치 또는
인터페이스입니다. DawnShell의 Debian은 Android가 준비한 NIC를 공유합니다.

### TUN — Network TUNnel

VPN 프로그램이 IP 패킷을 처리할 때 사용하는 가상 네트워크 장치입니다.
Tailscale의 커널 네트워크 모드에서 사용될 수 있습니다.

### NAT — Network Address Translation

여러 내부 주소를 다른 네트워크 주소로 바꾸는 기능입니다. Docker bridge가 NAT와
방화벽 규칙을 변경하면 Android 전체 네트워크에 영향을 줄 수 있습니다.

### cgroup — control group

Linux가 프로세스의 자원 사용과 장치 접근을 관리하는 기능입니다. DawnShell은
기기에서 실제로 사용할 수 있는 cgroup v2를 먼저 시험하고, 필요하면 v1 방식으로
전환합니다.

### BPF / eBPF — Berkeley Packet Filter / extended BPF

커널 안에서 검증된 작은 프로그램을 실행하는 기술입니다. DawnShell은 최신
cgroup v2에서 장치 접근 정책을 적용할 수 있는지 확인할 때 사용합니다.

### namespace

프로세스가 보는 PID, 마운트, 호스트 이름, 네트워크 같은 Linux 자원을 나누는
기능입니다. DawnShell은 필요한 자원만 나누며 Android 네트워크는 공유합니다.

### UTS — UNIX Time-sharing System namespace

Linux namespace 종류 중 하나입니다. 프로세스가 보는 호스트 이름과 도메인 이름을
분리합니다. DawnShell은 Debian 호스트 이름을 Android와 별도로 보이게 합니다.

### SELinux — Security-Enhanced Linux

일반 파일 권한 외에 추가 보안 정책을 적용하는 Linux 보안 기능입니다. Android는
앱과 시스템 서비스를 격리하는 데 SELinux를 사용합니다.

- [AOSP: Android 보안과 앱 격리](https://source.android.com/docs/security/app-sandbox)

### IPC — Inter-Process Communication

프로세스끼리 데이터를 주고받는 기능의 총칭입니다. Docker host IPC는 컨테이너가
Android 및 Debian과 IPC 객체를 공유하게 하므로 호환성은 좋아질 수 있지만 격리는
약해집니다.

### USBFS / raw USB

Linux 프로그램이 `/dev/bus/usb/버스/장치` node를 통해 USB request를 직접 보내는
interface입니다. DawnShell의 USB **끄기**는 이 raw interface를 차단하지만 Android
driver가 만든 저장장치나 네트워크 interface까지 숨기지는 않습니다.

### VID:PID

USB 장치의 vendor ID와 product ID를 각각 16진수 네 자리로 쓴 값입니다. 예:
`0403:6001`. 독점 패스스루는 목록과 정확히 일치하는 장치 interface만 분리합니다.

### memfd / eventfd

`memfd`는 메모리에 만든 익명 파일 descriptor이고, `eventfd`는 작은 event counter
descriptor입니다. DawnShell의 코덱 client가 직접 만든 뒤 직계 worker에게만
상속하여 영상 record와 알림을 주고받습니다.

## 자주 헷갈리는 표현

- **잠금 화면이 보입니다**와 **BFU입니다**는 같은 뜻이 아닙니다. 한 번 잠금을
  푼 뒤 화면을 다시 잠그면 저장소는 계속 AFU 상태입니다.
- **root 권한이 있습니다**와 **가상 머신처럼 안전하게 격리됩니다**는 같은 뜻이
  아닙니다. Debian root는 Android 커널과 네트워크를 공유합니다.
- **DE가 암호화됩니다**와 **PIN으로 보호됩니다**는 같은 뜻이 아닙니다. DE는
  PIN 입력 전에도 열리므로 비밀번호, 토큰, 개인 키를 저장하면 안 됩니다.
