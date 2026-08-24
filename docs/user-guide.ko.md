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

Android 재부팅은 이 `reboot` 명령을 통해서만 가능합니다. Debian과 그 안에서
실행되는 컨테이너는 커널에 직접 재부팅을 요청할 수 없습니다. 일부 커널은
컨테이너의 재부팅 요청을 격리하지 못해 기기 전체가 재시작되기 때문입니다.
Docker 컨테이너를 시작하거나 정리할 때 기기가 재부팅되는 문제가 이렇게
차단됩니다.

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

일부 커널은 컨테이너가 자체 IPC 네임스페이스를 만들 때 mqueue 처리에서 커널
패닉을 일으켜 Android 전체가 재시작됩니다. DawnShell은 Debian을 시작할 때
IPC 네임스페이스 생성 자체를 차단합니다. 따라서 `docker compose`나 API를
사용하는 클라이언트도 기기를 멈추게 할 수 없고, 대신 컨테이너가 권한 오류로
실패합니다.

**컨테이너에 호스트 IPC 사용**은 기본값으로 켜져 있습니다. 이 옵션은
`/usr/local/bin/docker` 래퍼가 `run`과 `create`에 `--ipc=host`를 자동으로
추가해, 컨테이너가 차단된 호출을 시도하지 않고 처음부터 정상 실행되게 합니다.

`docker compose`도 자동으로 처리됩니다. Compose는 IPC 설정을 YAML에서 읽으므로
래퍼가 임시 override 파일을 만들어 각 서비스에 `ipc: host`를 적용합니다.
compose 파일마다 직접 추가할 필요가 없습니다. 이미 `ipc:`를 지정한 서비스는
그 값이 유지됩니다.

호스트 IPC는 컨테이너가 Android 및 Debian의 IPC 객체를 공유하므로 격리가
약해집니다. 사용자가 명시한 `--ipc=...`는 언제나 우선합니다. 변경 후에는
**Docker 네트워크 정책 적용**을 눌러야 반영됩니다.

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

**끄기**는 정확히 raw USBFS 정책입니다. `/dev/bus/usb`를 가리고 문자 장치 major
189를 거부하지만 Android 커널의 USB 감지를 중단하지는 않으므로 공유 sysfs에서
장치가 계속 보일 수 있습니다. 또한 커널 드라이버가 만든 `/dev/block/sd*`, USB
Ethernet, `ttyUSB`/`ttyACM`, input, video, audio 같은 파생 자원은 raw USBFS 정책
범위 밖이며 장치 class별 추가 격리가 필요합니다.

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

## 7. 하드웨어 영상 코덱

Debian에서 영상을 인코딩하거나 디코딩할 때 Android의 전용 영상 코덱을 대신
사용하게 하는 기능입니다. GPU 패스스루가 아닙니다. Debian은 컨테이너 분해와
재조립만 담당하고, 실제 코덱 작업은 앱 프로세스가 수행한 뒤 결과만 돌려줍니다.

### 켜는 방법

1. 앱에서 **하드웨어 영상 코덱 브리지**를 켭니다.
2. **BFU 설정 저장 및 런타임 배치**를 누릅니다.
3. **Debian 13 systemd + SSH 구성**을 다시 실행합니다.
4. **코덱 자체 검사 실행**을 눌러 통과를 확인합니다.

구성이 끝나면 Debian에 다음 명령이 설치됩니다.

| 명령 | 용도 |
| --- | --- |
| `dawnshell-ffmpeg` | 기존 FFmpeg 명령을 그대로 받아 자동으로 하드웨어 처리 |
| `dawnshell-hwdecode` | H.264/HEVC 디코딩 |
| `dawnshell-hwencode` | I420 원본 영상을 H.264/HEVC로 인코딩 |
| `dawnshell-hwtranscode` | H.264/HEVC를 H.264로 재인코딩 |
| `dawnshell-codec-self-test` | 코덱 브리지 동작 확인 |

### 자동 연동

`dawnshell-ffmpeg`는 일반 `ffmpeg`와 같은 명령줄을 받습니다. 하드웨어로 똑같이
처리할 수 있으면 코덱 브리지로 보내고, 그렇지 않으면 원래 FFmpeg에 그대로
넘깁니다. 필터나 옵션이 조용히 무시되는 일은 없습니다.

```sh
dawnshell-ffmpeg -i input.mp4 -c:v libx264 -b:v 3M output.mp4
dawnshell-ffmpeg -i input.mp4 output.yuv
```

기존 프로그램이 수정 없이 이 경로를 타게 하려면 `ffmpeg`라는 이름으로 먼저
찾히게 하면 됩니다.

```sh
ln -s /usr/local/bin/dawnshell-ffmpeg /usr/local/bin/ffmpeg
```

`/usr/local/bin`이 `/usr/bin`보다 앞에 있으므로 Jellyfin 같은 프로그램도 그대로
하드웨어 경로를 사용합니다. 되돌리려면 이 심볼릭 링크를 지웁니다.

동작 방식은 환경 변수로 바꿀 수 있습니다.

| 값 | 동작 |
| --- | --- |
| `auto`(기본값) | 가능하면 하드웨어, 아니면 소프트웨어 |
| `off` | 항상 원래 FFmpeg 사용 |
| `require` | 하드웨어로 처리할 수 없으면 오류로 중단 |

```sh
DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg -i input.mp4 -c:v libx264 out.mp4
```

성능을 비교하거나 문제를 확인하려면 `require`로 실행해 실제로 하드웨어 경로를
타는지 확인하세요.

### 하드웨어로 처리되는 조건

- 입력이 H.264 또는 HEVC이고 영상 하나만 사용합니다.
- 출력 코덱이 `libx264`/`h264`이거나, 출력이 `.yuv`/`.i420` 원본입니다.
- 해상도가 16~4096이고 가로·세로가 짝수입니다.
- `-b:v`는 1000~100000000 범위입니다.

다음은 소프트웨어로 넘어갑니다.

- `-vf`, `-filter` 등 필터 사용
- `-crf`, `-preset` 같은 x264 전용 옵션
- 입력이 여러 개이거나 오디오를 함께 다루는 경우
- `-c:v copy`처럼 코덱 작업이 필요 없는 경우
- VP9, AV1 등 지원하지 않는 코덱

### 확인과 문제 해결

```sh
dawnshell-codec health --format json
dawnshell-codec-self-test
```

앱의 **파일 기반 하드웨어 AVC 디코드 자체 검사** 버튼은 Debian에 `wget`과
`ca-certificates`가 없으면 `apt`로 먼저 설치한 뒤, test-videos.co.uk의 Big Buck
Bunny 1920x1080 H.264 MP4를 Debian에서 다운로드합니다. 앱은 다운로드된 파일을
DE 검사 디렉터리로 넘겨 `MediaExtractor`와 하드웨어 `MediaCodec`으로 직접
디코드합니다. 영상 데이터는 Unix 소켓을 통과하지 않으며 검사 로그의
`socket_media_bytes=0`으로 이를 확인할 수 있습니다. 첫 실행은 패키지 설치와 약
5 MB 다운로드 때문에 시간이 더 걸릴 수 있습니다.

`dawnshell-codec-self-test`는 별도의 고급 스트리밍 브리지 검사입니다. 파일 기반
검사가 성공해도 이 명령이 실패한다면 하드웨어 코덱 자체가 아니라 소켓/공유
메모리 스트리밍 계층 문제로 구분할 수 있습니다.

`backend`에 실제 선택된 코덱 이름이 표시됩니다. 소프트웨어 코덱이 조용히
선택되는 일은 없으며, 하드웨어를 쓸 수 없으면 명확한 오류를 남깁니다. 코덱
기능이 실패해도 Debian과 SSH는 계속 동작합니다.

BFU에서 코덱이 실패한다면 Android 미디어 서비스가 아직 준비되지 않았을 수
있습니다. 잠금 해제 후 다시 시도해 차이를 확인하세요.

## 8. 로그 확인

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

## 9. 네트워크

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

## 10. 백업과 제거

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
