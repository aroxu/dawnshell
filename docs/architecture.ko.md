# DawnShell 아키텍처

[English](architecture.md) · [쉬운 용어집](glossary.ko.md)

이 문서는 DawnShell이 BFU(Before First Unlock, 최초 잠금 해제 전)에서 Debian을
어떻게 시작하고, 어떤 보안 경계를 지키는지 설명합니다.

## 전체 구조

DawnShell은 다른 앱과 UID(User Identifier)를 공유하지 않는 독립 Android
앱입니다. Android는 앱마다 고유 UID를 할당해 기본적인 앱 격리를 제공합니다.
자세한 내용은 [AOSP 앱 샌드박스 문서](https://source.android.com/docs/security/app-sandbox)를
참고해 주세요.

```text
LOCKED_BOOT_COMPLETED
  → BootReceiver
  → BfuBootstrapService(포그라운드 서비스)
  → DE 저장소와 root 권한 확인
  → Debian rootfs 검증
  → 네임스페이스와 cgroup 준비
  → systemd를 Debian PID 1로 시작
  → OpenSSH 시작

USER_UNLOCKED
  → 잠금 해제 이벤트 기록
  → 실행 중인 Debian은 그대로 유지
```

Android가 BFU 앱을 실행하려면 receiver와 service에 `directBootAware=true`가
필요합니다. 공식 요구 사항은
[Google Direct Boot 문서](https://developer.android.com/privacy-and-security/direct-boot#request_access)에서
확인할 수 있습니다.

## 저장소 경계

### 앱 DE 저장소

DE(Device Encrypted) 저장소는 PIN 입력 전에도 열립니다. 앱은 경로를 직접
하드코딩하지 않고 `createDeviceProtectedStorageContext()`로 찾습니다.

- 부팅 설정
- 공개 SSH 키
- 네이티브 실행 파일
- 상태 표식과 로그

[Google Context API](https://developer.android.com/reference/android/content/Context#createDeviceProtectedStorageContext())에서
공식 사용 방법을 확인할 수 있습니다.

### 앱 CE 저장소

CE(Credential Encrypted) 저장소는 첫 잠금 해제 뒤에 열립니다. SSH 클라이언트
개인 키처럼 BFU에 필요하지 않은 비밀은 CE에만 저장합니다. 부팅 단계에서는
CE가 실제로 닫혀 있는지 sentinel로 검사합니다.

### Debian rootfs

Debian 전체 파일은 `/data/local/debian`에 있습니다. 앱은 고정된 이 경로만
관리하며 사용자가 전달한 임의 경로를 root 명령에 넣지 않습니다.

FBE(File-Based Encryption), DE, CE의 관계는
[AOSP 파일 기반 암호화 문서](https://source.android.com/docs/security/features/encryption/file-based)와
[용어집](glossary.ko.md#android-부팅과-저장소)을 참고해 주세요.

## 부트스트랩 런타임

APK에는 세 ABI(Application Binary Interface)용 최소 도구가 포함됩니다.

| Android ABI | Debian 아키텍처 |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

각 런타임에는 BusyBox 도구 모음, `pkgdetails`, 정적으로 연결한 `gpgv`, Debian
archive keyring, 네임스페이스 런처가 포함됩니다. 앱은 Debian Release 서명,
패키지 목록, 패키지 해시를 확인한 뒤 rootfs를 게시합니다.

## root 실행 경계

Magisk 승인은 Android 잠금이 풀린 AFU(After First Unlock)에서 미리 받아야
합니다. BFU에는 승인 화면이 없으므로 부팅 코드는 사전 승인된 `su`만 사용합니다.

root helper는 다음 원칙을 지킵니다.

- 실행할 동작을 고정된 operation ID로 제한합니다.
- rootfs 경로를 `/data/local/debian`으로 고정합니다.
- 비밀번호와 개인 키를 명령행 또는 로그에 넣지 않습니다.
- Android 호스트의 `/data`를 다시 마운트하지 않습니다.
- 중지와 삭제 전에 대상 프로세스와 경로를 다시 확인합니다.

## systemd 실행 공간

런처는 Linux namespace를 사용해 Debian이 보는 환경을 구성합니다.

- mount namespace는 Debian 전용 마운트를 분리합니다.
- PID namespace는 Debian의 systemd를 PID(Process Identifier) 1로 보이게 합니다.
- UTS namespace는 Debian 호스트 이름을 분리합니다.
- cgroup namespace는 위임된 자원 관리 계층만 보여 줍니다.
- network namespace는 분리하지 않고 Android 네트워크를 공유합니다.

Debian 종료 시에는 systemd 종료를 기다린 뒤 자식 프로세스, 마운트, cgroup
하위 트리를 정리합니다.

## cgroup 선택

cgroup(control group)은 프로세스 자원과 장치 접근을 관리합니다. DawnShell은
다음 순서로 실제 기능을 시험합니다.

1. 전용 cgroup v2 하위 트리를 만듭니다.
2. 장치 정책용 BPF(Berkeley Packet Filter) 프로그램을 load/attach합니다.
3. 성공하면 v2를 사용합니다.
4. 실패하면 시험 자원을 모두 정리합니다.
5. 격리된 cgroup v1 `devices`와 `name=systemd` 방식으로 전환합니다.

Android 전역 cgroup을 Debian에 그대로 공개하지 않습니다. Docker가 Android
프로세스의 장치 정책까지 바꾸는 위험을 줄이기 위해 전용 하위 트리만 제공합니다.

## 네트워크

Debian은 Android의 network namespace와 NIC(Network Interface Controller)를
공유합니다. Wi-Fi, 모바일 데이터, USB Ethernet이 나중에 연결되어도 Debian을
다시 시작할 필요가 없습니다.

이 설계는 빠르지만 Docker bridge 설정이 Android 전체에 영향을 줄 수 있습니다.
따라서 기본 Docker 정책은 host-network-only이며, bridge 방식은 사용자가 경고를
확인하고 직접 적용해야 합니다.

## SSH 키 흐름

1. 사용자가 잠금을 해제한 뒤 앱이 임의 Ed25519 키 쌍을 생성합니다.
2. 개인 키는 앱 CE에 저장합니다.
3. 공개 키만 앱 DE와 Debian의 `authorized_keys`에 배치합니다.
4. 사용자가 명시적으로 요청할 때만 개인 키 파일 또는 가져오기 명령을
   내보냅니다.
5. 공개 키가 바뀌면 systemd + SSH 구성을 다시 실행합니다.

## 중복 실행 방지

서비스는 현재 boot ID와 supervisor PID를 기록합니다. 같은 부팅에서 알림이
중복되거나 서비스가 다시 호출되어도 이미 검증된 Debian 인스턴스를 재사용합니다.
비정상적으로 남은 PID 파일은 실제 프로세스의 UID, 실행 파일, namespace를
확인한 뒤에만 정리합니다.

## 관련 문서

- [쉬운 용어집](glossary.ko.md)
- [보안 모델](security.ko.md)
- [Debian systemd 구성](debian-systemd.ko.md)
- [테스트 방법](testing.ko.md)
