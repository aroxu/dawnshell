# DawnShell 사용자 매뉴얼

[English](user-guide.md)

[프로젝트 홈](../README.ko.md) · [설치 가이드](installation.ko.md) ·
[쉬운 용어집](glossary.ko.md) · [문제 해결](#문제-해결)

이 문서는 설치를 마친 뒤 DawnShell을 사용하는 방법을 설명합니다. Debian과
SSH를 아직 구성하지 않았다면 먼저 [설치 가이드](installation.ko.md)를 따라 주세요.

## 먼저 알아둘 내용

- BFU(Before First Unlock)는 재부팅 후 첫 잠금 해제 전 상태입니다.
- AFU(After First Unlock)는 재부팅 후 잠금을 한 번 이상 해제한 상태입니다.
- DawnShell은 BFU에서 Debian `systemd`와 SSH를 시작합니다.
- 잠금을 해제해도 같은 Debian과 SSH가 계속 실행됩니다.
- Debian은 Android 네트워크를 공유하므로 일반 가상 머신처럼 완전히 격리되지
  않습니다.

DE, CE, rootfs, PID 같은 표현은 [쉬운 용어집](glossary.ko.md)에 설명되어 있습니다.
Direct Boot 자체의 동작은 [Google 공식 문서](https://developer.android.com/privacy-and-security/direct-boot)에서
확인할 수 있습니다.

## 1. Direct Boot

**다이렉트 부트 Debian 부트스트랩 활성화**는 다음 재부팅부터 자동으로 Debian을
시작할지 결정합니다. 스위치를 바꾼 뒤에는 반드시 **BFU 설정 저장 및 런타임
배치**를 누릅니다.

**Magisk 루트 권한 요청 / 확인**은 현재 앱이 root를 사용할 수 있는지 확인합니다.
BFU에서는 Magisk 승인 창을 띄울 수 없으므로 미리 영구 허용해야 합니다.

**BFU 검사 결과 새로고침**은 마지막 부팅 때 기록된 결과를 읽습니다. 잠금 해제
후 이 버튼을 눌러도 BFU 검사가 새로 실행되지는 않습니다.

**CE 저장소를 읽을 수 있는 BFU 환경 허용**은 위험한 예외 옵션입니다. 정상적인
FBE(File-Based Encryption) 기기에서는 꺼 둡니다. 이 옵션은 암호화를 고치는
기능이 아니며, ROM이 이미 CE를 노출하는 위험을 사용자가 수락할 때만 차단을
해제합니다.

## 2. Debian 설치와 구성

**Debian 13 Trixie rootfs 설치**는 `/data/local/debian`에 Debian 전체 파일
구조를 만듭니다. 기존의 정상 설치를 자동으로 덮어쓰지 않습니다.

**Debian 13 systemd + SSH 구성**은 다음 항목을 준비합니다.

- systemd와 D-Bus
- OpenSSH 서버
- `debian` 사용자
- 앱이 생성한 공개 키
- 부팅 성공을 확인하는 서비스

두 작업은 Android 잠금을 해제한 상태에서만 시작할 수 있습니다. 진행 상황은
각각 **Debian 설치**와 **시스템 구성** 로그에서 확인합니다.

## 3. 서버 제어

- **시작**은 설치 상태를 확인한 뒤 Debian systemd를 시작합니다.
- **재시작**은 기존 인스턴스를 정상 종료한 뒤 새로 시작합니다.
- **상태**는 systemd, D-Bus, SSH, TCP 22, cgroup 상태를 확인합니다.
- **중지**는 Debian 서비스를 정리하고 SSH를 중지합니다.

Android 잠금 해제 이벤트는 서버를 중지하지 않습니다. 수동으로 중지했다면
**시작**을 누르거나 다음 재부팅 때 자동 시작을 기다립니다.

## 4. SSH로 접속

다른 PC에서는 **SSH 개인 키 파일 내보내기**를 사용하는 방법을 권장합니다.

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

같은 휴대폰의 신뢰할 수 있는 로컬 셸에서는 다음 순서로 진행합니다.

1. **로컬 셸용 개인 키 가져오기 명령 복사**를 누릅니다.
2. 경고를 확인하고 복사한 명령을 본인의 로컬 셸에서 한 번 실행합니다.
3. **SSH 접속 명령 복사**를 누르고 복사한 명령을 실행합니다.

가져오기 명령에는 SSH 개인 키 전체가 포함됩니다. 메신저, 공유 화면, 다른 앱의
셸에 붙여 넣지 마세요. 클립보드는 120초 뒤 지워지지만, 가능하면 파일 내보내기를
사용해 주세요.

**새 임의 SSH 클라이언트 키 생성**은 기존 키를 영구 교체합니다. 교체할 때는
다음 순서를 지킵니다.

1. 필요한 기존 개인 키를 백업합니다.
2. 새 키를 생성합니다.
3. **Debian 13 systemd + SSH 구성**을 다시 실행합니다.
4. 새 개인 키를 다시 내보냅니다.
5. 새 키로 접속한 뒤 이전 파일을 폐기합니다.

rootfs 재설치 후 SSH 호스트 키 경고가 발생하면 실제 재설치 여부를 확인한 뒤
해당 주소의 항목만 지웁니다.

```sh
ssh-keygen -R "[PHONE_IP]:22"
```

## 5. 계정과 root 전환

앱에서 `root`와 `debian`의 로컬 비밀번호를 각각 설정할 수 있습니다. 비밀번호는
Debian의 `chpasswd`에 직접 전달되며 앱 설정, DE 저장소, 로그에 저장되지
않습니다. SSH 비밀번호 인증은 계속 꺼진 상태로 유지됩니다.

SSH로 `debian`에 접속한 뒤 root로 전환하려면 다음 명령을 실행합니다.

```sh
su root
```

앱에서 설정한 root 비밀번호를 입력합니다. root 셸에서 나가려면 `exit`를
실행합니다. 이 root는 Android 기기 수준 권한을 사용할 수 있으므로 신뢰한
명령만 실행해 주세요.

Android 전체를 재부팅하려면 root 셸에서 다음 명령을 사용합니다.

```sh
reboot --check
reboot now
```

`reboot --check`는 연결 기능만 확인합니다. `reboot now`는 Android 기기 전체를
즉시 재부팅합니다. `systemctl reboot`는 Debian 격리 환경 시험용이므로 Android
재부팅 명령으로 사용하지 않습니다.

## 6. 커널과 Docker

cgroup(control group)은 Linux가 프로세스 자원과 장치 접근을 관리하는
기능입니다. 기본값인 **자동: v2 → v1**을 권장합니다. v2가 실제 기기에서
동작하지 않으면 DawnShell이 정리 후 v1 방식으로 전환합니다.

Docker는 기본적으로 **안전한 호스트 네트워크만 사용**을 선택합니다.

```sh
docker run --network host ...
```

DawnShell은 위임된 비공개 cgroup 계층 안에서 Docker의 cgroup driver를
`cgroupfs`로 고정합니다. 따라서 Android 구형 커널 호환 환경의 systemd에
컨테이너 transient scope 생성을 요청하지 않습니다. `docker info --format
'{{.CgroupDriver}}'` 결과가 `cgroupfs`인지 확인할 수 있습니다.

커널에서 컨테이너의 private IPC 또는 mqueue 마운트가 실패하면 **Docker
run/create에 호스트 IPC 자동 적용**을 켠 뒤 **Docker 네트워크 정책 적용**을
누릅니다. 관리형 `/usr/local/bin/docker` 래퍼가 `run`과 `create`에
`--ipc=host`를 추가합니다. 사용자가 명시한 `--ipc=...`가 우선하며
`/usr/bin/docker`로 래퍼를 우회할 수 있습니다. 호스트 IPC는 컨테이너 격리를
낮추고 공유 IPC 객체를 컨테이너에 노출합니다.

bridge 모드는 Android 전체의 방화벽, NAT(Network Address Translation), 경로와
전달 설정을 변경할 수 있습니다. Wi-Fi, 모바일 데이터, USB Ethernet, VPN,
Tailscale, 현재 SSH 연결이 끊길 수 있습니다. 별도 복구 방법이 없으면 강제 bridge
옵션을 사용하지 마세요. 설정은 **Docker 네트워크 정책 적용**을 누를 때만
반영됩니다.

### USB 패스스루

USB 패스스루는 기본적으로 꺼져 있습니다. **USB 공유 정책 적용**을 누르면 실행
중인 Debian만 재시작하고, 중지 상태라면 임의로 시작하지 않고 다음 시작부터
적용합니다. USB Ethernet은 Debian이 Android network namespace를 이미 공유하므로
이 설정이 필요하지 않습니다.

구형 커널에서 Debian 13의 `lsusb -t`는 커널에 없는 최신 `rx_lanes`와
`tx_lanes` sysfs 속성을 조회할 수 있습니다. DawnShell은 USB 정책 적용 때 관리형
호환 래퍼를 설치하여 이 속성의 예상된 `ENOENT` 메시지만 숨기고 다른 USB 오류는
그대로 표시합니다.

- **직접 패스스루**는 `/dev/bus/usb`를 노출하고 hot-plug를 반영하되 Android
  커널 드라이버 연결을 유지합니다. 일반 libusb 확인에는 먼저 이 모드를 씁니다.
- **독점 패스스루**는 정확한 `VID:PID`를 입력한 장치의 모든 interface를 추가로
  unbind합니다. `0403:6001, 10c4:ea60`처럼 쉼표 또는 공백으로 구분하며 하나
  이상이 필수입니다. 새로 연결된 일치 장치도 감시하고 Debian 종료 때 분리한
  드라이버 복원을 시도합니다.

```sh
ls -l /dev/bus/usb/*/* 2>/dev/null
lsusb 2>/dev/null || true
dmesg | tail -n 100
```

USB 시리얼, 저장장치, 카메라, 오디오와 입력 장치는 Android 커널이 지원해야
합니다. root라도 SELinux가 접근을 거부할 수 있습니다. 독점 모드는 Android
입력, 저장장치, 네트워크, ADB 또는 복구 연결을 끊을 수 있으므로 고장 나도 되는
주변기기와 별도 복구 수단으로 시험하세요. 비정상 종료 뒤에는 장치를 뽑거나
재부팅해야 할 수 있습니다. 휴대전화 내부 USB/gadget controller는 선택하지 말고,
같은 USB 저장장치 파일시스템을 양쪽에서 동시에 마운트하지 마세요. Docker에는
필요한 노드를 `--device`로 별도 전달하고 `--privileged`는 피하세요.

## 7. 로그 확인

상단의 **로그**에서 다음 화면을 열 수 있습니다.

- 앱 작업
- Debian 설치
- 시스템 구성
- 호환성 정책
- 서버 수명 주기
- Direct Boot 진단

로그는 1초마다 갱신됩니다. 길게 눌러 필요한 부분을 선택하거나 전체 내용을
복사할 수 있습니다. 이전 줄을 읽기 위해 위로 스크롤하면 자동 따라가기가
멈춥니다. 오류를 공유할 때는 개인 키와 비밀번호를 추가하지 마세요.

## 8. 네트워크

SSH 서버는 Android 네트워크 주소가 아직 없어도 TCP 22에서 대기합니다. Android가
나중에 Wi-Fi, 모바일 데이터 또는 USB Ethernet 주소를 준비하면 Debian을 다시
시작하지 않아도 접속할 수 있습니다.

같은 Wi-Fi의 PC에서는 다음과 같이 접속합니다.

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

같은 휴대폰에서는 앱이 복사해 주는 localhost 접속 명령을 사용합니다.

Tailscale을 커널 네트워크 모드로 사용하면 `tailscale0` 장치와 경로 설정이
Android와 공유됩니다. 재사용 인증 키를 BFU rootfs에 저장하지 마세요.
`tailscaled.state`도 PIN 입력 전 사용할 수 있는 기기 인증 정보로 취급합니다.

## 9. 백업과 제거

다음 항목을 백업하는 것을 권장합니다.

- 앱에서 내보낸 SSH 클라이언트 개인 키
- Debian의 필요한 `/etc` 설정과 사용자 데이터
- 설치한 패키지 목록과 서비스 설정

앱을 제거하면 앱 DE/CE와 생성한 키는 삭제되지만 `/data/local/debian`은 남습니다.
Debian까지 완전히 삭제하려면 다음 순서로 진행합니다.

1. 필요한 데이터와 키를 백업합니다.
2. **중지**를 누르고 **상태**에서 systemd가 종료됐는지 확인합니다.
3. **위험 구역 → Debian rootfs 영구 삭제**를 누릅니다.
4. 두 확인 창을 읽고 `DELETE`를 입력합니다.
5. 로그에서 `DEBIAN_ROOTFS_REMOVE_SUCCEEDED`를 확인합니다.
6. Android 설정에서 DawnShell 앱을 제거합니다.

## 문제 해결

### 재부팅 후 BFU에서 시작하지 않습니다

- 설정 변경 후 **BFU 설정 저장 및 런타임 배치**를 눌렀는지 확인합니다.
- Magisk에서 DawnShell이 영구 허용인지 확인합니다.
- 잠금 해제 후 Direct Boot 진단 로그의 `LOCKED_BOOT_COMPLETED`, root, CE 격리,
  rootfs, chroot 결과를 순서대로 확인합니다.
- 제조사 배터리와 자동 시작 제한에서 앱을 제외합니다.

### root가 거부되거나 시간이 초과됩니다

잠금 해제 상태에서 root 승인 버튼을 다시 누릅니다. Magisk에서 영구 허용으로
바꿉니다. BFU에서는 승인 창을 표시할 수 없습니다.

### Debian 설치가 실패합니다

Debian 설치 로그의 마지막 `ERROR:`와 `DEBOOTSTRAP_LOG_TAIL`을 복사합니다.
서명 또는 해시 검증 오류를 우회하지 마세요. 진단하기 전에 임시 폴더를 무작정
지우지 않습니다.

### systemd와 SSH 구성이 시작되지 않습니다

Android 잠금이 해제되었는지, Direct Boot 설정을 저장했는지, Debian 설치가
`SUCCEEDED`인지, root 권한이 유효한지 확인합니다. 시스템 구성 로그의 첫 실패
단계를 확인합니다.

### SSH 연결이 거부됩니다

1. 앱의 **상태**와 서버 수명 주기 로그를 확인합니다.
2. systemd와 SSH 구성이 성공했는지 확인합니다.
3. Debian에서 `systemctl is-active ssh.service`와 `ss -ltn`을 확인합니다.
4. 다른 프로세스가 TCP 22를 사용 중인지 확인합니다.
5. 원격 접속이라면 Android가 BFU에서 실제 IP 주소를 받았는지 확인합니다.

### `network is unreachable`가 표시됩니다

같은 휴대폰의 `127.0.0.1` 접속은 되지만 외부 접속만 실패한다면 Android의
인터페이스, 주소, 경로를 확인합니다. ROM이 BFU에서 Wi-Fi 인증 정보를 열지
않으면 DawnShell이 대신 연결할 수 없습니다.

### Docker 설정 뒤 네트워크가 끊겼습니다

가능하면 로컬 화면이나 ADB 같은 별도 복구 경로로 앱을 열고 **안전한 호스트
네트워크만 사용**을 선택해 다시 적용합니다. 호환성 로그도 함께 확인합니다.

## 관련 문서

- [설치 가이드](installation.ko.md)
- [쉬운 용어집](glossary.ko.md)
- [보안 모델](security.ko.md)
- [아키텍처](architecture.ko.md)
- [테스트 방법](testing.ko.md)
