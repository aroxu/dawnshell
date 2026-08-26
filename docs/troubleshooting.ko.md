# DawnShell 문제 해결 가이드

[English](troubleshooting.md) · [문서 홈](README.ko.md) · [사용자 매뉴얼](user-guide.ko.md) · [테스트 방법](testing.ko.md)

이 문서는 오류가 발생했을 때 가장 안전한 순서로 원인을 좁히는 방법을 설명합니다.
위에서부터 무작정 모든 명령을 실행하지 말고, 현재 증상과 같은 절만 확인하세요.

> **안전 원칙**
>
> 서명·해시·CE 격리 오류를 우회하지 마세요. Docker bridge나 USB 독점 모드로
> 네트워크 또는 ADB가 끊길 수 있으므로 변경 전에는 휴대전화 화면처럼 독립된 복구
> 수단을 준비하세요. 로그에 개인 키, 비밀번호, 토큰을 붙이지 마세요.

## 먼저 수집할 기본 정보

앱에서 **실시간 로그**를 열고 증상에 맞는 로그를 복사합니다. 다음 정보도 함께
기록하면 원인을 훨씬 빨리 찾을 수 있습니다.

```sh
uname -a
dpkg --print-architecture
cat /etc/debian_version
cat /proc/1/comm
systemctl is-active ssh.service
ip -brief address
```

ADB를 사용할 수 있다면 Android 쪽 기본 정보는 다음으로 확인합니다.

```sh
adb shell getprop ro.build.version.release
adb shell getprop ro.product.cpu.abilist
adb shell dumpsys package me.aroxu.dawnshell
adb shell dumpsys user
```

ADB는 BFU 성공에 필요한 권한이 아닙니다. 일부 ROM은 첫 잠금 해제 전 ADB를
허용하지 않으므로, BFU 검증은 다른 기기의 SSH 접속 결과를 기준으로 합니다.

## root 권한을 받지 못합니다

증상:

- root 검사에 `root=false`, `exit`가 0이 아닌 값, 또는 timeout이 표시됩니다.
- BFU 로그가 root 검사에서 멈춥니다.

확인 순서:

1. Android 잠금을 해제합니다. BFU에서는 Magisk 승인 창을 띄울 수 없습니다.
2. 앱의 **Magisk 루트 권한 요청 / 확인**을 누릅니다.
3. Magisk에서 패키지 `me.aroxu.dawnshell`을 **영구/항상 허용**으로 승인합니다.
4. 결과에 `uid=0`, `root=true`, `exit=0`이 있는지 확인합니다.
5. Magisk의 Superuser 목록에서도 정책이 영구 저장됐는지 확인합니다.

앱의 검사는 현재 root가 동작함을 증명하지만 Magisk의 승인 유효 기간까지 읽을 수는
없습니다. “한 번만 허용”은 다음 cold boot의 BFU에서 동작하지 않습니다.

## 재부팅 뒤 BFU에서 Debian이 시작하지 않습니다

다음 순서로 **Direct Boot 진단** 로그를 확인합니다.

1. `LOCKED_BOOT_COMPLETED received`
2. DE 런타임 검증
3. root 검사
4. CE 격리 검사
5. `/data/local/debian` rootfs 검사
6. namespace/chroot 검사
7. systemd와 SSH 상태

흔한 원인과 조치는 다음과 같습니다.

| 로그 또는 상태 | 뜻 | 조치 |
| --- | --- | --- |
| 부팅 broadcast 기록 없음 | 앱이 Direct Boot에서 실행되지 않았습니다. | 앱을 한 번 열어 설정을 저장하고, 제조사 자동 시작·배터리 제한에서 제외합니다. |
| root 승인 실패 | BFU에서 `su`가 대화형 승인을 기다립니다. | 잠금 해제 뒤 영구 root 승인을 다시 설정합니다. |
| `BFU_APP_CE_CONTENT_ACCESSIBLE` | ROM이 첫 잠금 해제 전 앱 CE를 노출합니다. | 기본 차단을 유지하고 ROM/FBE 구성을 점검합니다. 위험 예외는 의미를 이해한 경우에만 사용합니다. |
| rootfs/ready marker 없음 | 설치 또는 systemd 구성이 완료되지 않았습니다. | 잠금 해제 뒤 설치와 구성을 순서대로 다시 실행합니다. |
| namespace/cgroup 실패 | 커널이 선택한 격리 방식을 지원하지 않습니다. | cgroup을 **자동: v2 → v1**로 되돌리고 다시 저장합니다. |

화면을 한 번 잠갔다고 다시 BFU가 되지는 않습니다. BFU 검사는 반드시 **재부팅 후
첫 잠금 해제 전**에 수행합니다.

## Debian 설치가 실패합니다

앱에서 **로그 → Debian 설치**를 열고 마지막 `ERROR:`와
`DEBOOTSTRAP_LOG_TAIL`을 복사합니다.

| 증상 | 확인할 내용 |
| --- | --- |
| Release 서명 실패 | 기기 시간, HTTPS 연결, 내장 Debian keyring과 APK 버전을 확인합니다. 우회하지 않습니다. |
| SHA-256 불일치 | 손상된 다운로드일 수 있습니다. 네트워크를 안정화한 뒤 다시 시도합니다. |
| 공간 부족 | Android 내부 저장 공간을 확보합니다. |
| `stat: invalid option -- c` | 오래된 부트스트랩 런타임입니다. 최신 APK에서 BFU 런타임을 다시 배치합니다. |
| 아키텍처 불일치 | Android ABI와 Debian `armhf`/`arm64`/`amd64` 대응을 확인합니다. |
| `/data/local/debian`이 이미 존재 | 정상 설치를 덮어쓰지 않는 안전 동작입니다. 기존 데이터를 백업하고 위험 구역의 삭제 절차를 사용합니다. |

실패한 staging tree는 다음 시도에서
`/data/local/debian.failed.<timestamp>`로 옮겨질 수 있습니다. 진단하기 전에 직접
삭제하지 마세요.

## systemd와 SSH 구성이 실패합니다

구성은 Android 잠금이 해제된 상태에서만 실행됩니다. 다음을 확인합니다.

1. Debian 설치 상태가 `SUCCEEDED`입니다.
2. 앱이 만든 SSH 공개 키가 화면에 표시됩니다.
3. root 권한이 현재 동작합니다.
4. 다른 설치·구성 작업이 실행 중이지 않습니다.
5. **시스템 구성** 로그에서 처음 실패한 `STAGE:` 바로 뒤 오류를 확인합니다.

Debian에 접속할 수 있다면 다음 상태를 확인합니다.

```sh
systemctl --failed --no-pager
systemctl status dbus.service ssh.service --no-pager
journalctl -b -p warning --no-pager | tail -n 200
ss -ltnp | grep ':22 '
```

SSH 키를 새로 생성했다면 **Debian 13 systemd + SSH 구성**을 다시 실행해야 새
공개 키가 `authorized_keys`에 반영됩니다.

## SSH 연결이 거부됩니다

`Connection refused`는 IP 주소까지는 도달했지만 TCP 22에서 서버가 듣고 있지
않다는 뜻입니다.

1. 앱의 **상태**와 **서버 수명 주기** 로그를 확인합니다.
2. Debian에서 다음 명령을 실행합니다.

```sh
systemctl is-active ssh.service
systemctl status ssh.service --no-pager
ss -ltnp | grep ':22 '
journalctl -u ssh.service -n 100 --no-pager
```

3. 다른 SSH 서버가 TCP 22를 차지했는지 확인합니다.
4. 명령에 `-p 22`와 올바른 `PHONE_IP`가 있는지 확인합니다.

```sh
ssh -vvv -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

`Permission denied (publickey)`는 서버는 열려 있지만 키가 맞지 않는 경우입니다.
현재 키를 내보내고, 키를 교체했다면 systemd + SSH 구성을 다시 실행하세요.

rootfs 재설치 뒤 호스트 키 경고가 나오면 재설치가 맞는지 먼저 확인한 뒤 해당 주소의
항목만 삭제합니다.

```sh
ssh-keygen -R "[PHONE_IP]:22"
```

## `network is unreachable` 또는 외부에서만 접속되지 않습니다

같은 휴대전화의 `127.0.0.1` 접속은 되는데 다른 기기에서 안 된다면 SSH보다
Android 네트워크 문제일 가능성이 큽니다.

```sh
ip -brief link
ip -brief address
ip route
ip -6 route
```

DawnShell은 주소가 없어도 SSH listener를 유지합니다. Android가 나중에 Wi-Fi,
모바일 데이터 또는 USB Ethernet을 올리면 Debian 재시작 없이 접속돼야 합니다.
단, ROM이 BFU에서 Wi-Fi 자격 증명을 열지 않으면 DawnShell이 대신 잠금을 풀거나
네트워크를 연결할 수 없습니다.

Tailscale의 `network is unreachable`도 먼저 Android가 기본 경로를 가지고 있는지
확인합니다. BFU rootfs에 재사용 auth key를 저장하지 마세요.

## croc 송수신이 시작되지 않고 계속 기다립니다

`croc`은 명시적인 파일 이름보다 먼저 non-TTY 표준 입력을 읽습니다. SSH 명령
실행기나 프로세스 관리자가 아무 데이터도 쓰지 않은 입력 pipe를 계속 열어 두면,
croc은 public IP 초기화 직후 입력을 기다리며 멈춘 것처럼 보입니다.

DawnShell 업데이트 후 **Debian 13 systemd + SSH 구성**을 다시 실행하세요. 이 작업은
`/usr/local/bin/croc` 호환 래퍼를 설치합니다. 래퍼는 명시적인 파일, text payload,
수신 code 또는 수신용 `CROC_SECRET`이 있을 때만 `--ignore-stdin`을 자동으로
추가합니다. 의도적인 pipe 전송은 그대로 유지합니다.

```sh
type -a croc
croc --debug --transport relay send file.bin
croc --debug --transport relay RECEIVE-CODE

# 명시적인 파일이 없는 pipe 전송은 기존 croc 동작을 유지합니다.
printf 'hello\n' | croc send

# DawnShell 래퍼를 우회해 원본 croc을 직접 진단합니다. 수동 설치본은
# libexec에 보존되고 Debian 패키지판은 /usr/bin에 남습니다.
/usr/local/libexec/dawnshell-croc-real --debug send file.bin
/usr/bin/croc --debug send file.bin
```

기존 `/usr/local/bin/croc` 수동 설치본은
`/usr/local/libexec/dawnshell-croc-real`에 보존하고, Debian 패키지의
`/usr/bin/croc`은 이동하지 않습니다. 래퍼는 relay를 강제로 선택하거나 전송
secret을 저장하지 않습니다. 그래도 기다린다면 upstream 옵션을 직접 지정하고
debug 출력을 보관하세요.

```sh
croc --debug --ignore-stdin --transport relay send file.bin
```

## 시작·중지·재시작이 실패합니다

버튼 요청은 즉시 전달됩니다. **서버 수명 주기** 로그에서 요청 시각과 첫 실패
단계를 확인합니다.

```sh
cat /proc/1/comm
systemctl is-system-running
systemctl --failed --no-pager
```

중지 실패에서 “현재 Debian PID 1이 종료됐음을 증명할 수 없음”이 나오면 앱은
잘못된 프로세스를 죽이지 않기 위해 중단한 것입니다. PID, 실행 파일, namespace,
boot ID 확인 결과를 함께 수집하세요. 직접 광범위한 `killall`이나 `/data` 삭제를
실행하지 마세요.

## Docker가 시작되지 않거나 Android 네트워크가 끊깁니다

먼저 앱 설정을 다음 권장값으로 되돌립니다.

- cgroup: **자동: cgroup v2 → v1 전환**
- Docker 네트워크: **안전한 호스트 네트워크만 사용**
- 컨테이너 호스트 IPC: **켬**

그다음 **Docker 네트워크 정책 적용**을 누릅니다. Debian에서 확인합니다.

```sh
docker info --format 'cgroup={{.CgroupDriver}} driver={{.Driver}}'
systemctl status docker.service containerd.service --no-pager
journalctl -u docker.service -n 200 --no-pager
```

권장 cgroup driver는 `cgroupfs`입니다. 기본 정책에서는 다음처럼 host network를
명시합니다.

```sh
docker run --rm --network host hello-world
```

| 오류 | 원인과 조치 |
| --- | --- |
| nftables/iptables `Invalid argument` | 커널 netfilter backend가 Docker 설정과 맞지 않습니다. 안전한 host-only로 되돌리거나 자동 backend 검사를 사용합니다. |
| `BPF_PROG_ATTACH ... operation not permitted` | 선택된 cgroup v2 장치 정책을 커널/SELinux가 허용하지 않습니다. 자동 정책으로 v1 fallback을 허용합니다. |
| `/dev/mqueue ... device or resource busy` | 일부 커널의 private IPC/mqueue 경로 문제입니다. 관리형 host IPC 옵션을 켜고 정책을 다시 적용합니다. |
| `failed to unshare remaining namespaces` | 위험한 namespace 생성이 DawnShell 안전 정책 또는 커널에서 차단됐습니다. wrapper가 `--ipc=host`를 적용하는지 확인합니다. |
| `/etc/resolv.conf: operation not permitted` | container mount callback과 커널/SELinux가 충돌했습니다. daemon 로그와 사용한 compose 설정을 수집하고 반복 재시작하지 않습니다. |

Docker bridge 모드는 Android 전역 방화벽, NAT, forwarding, route를 바꿀 수
있습니다. 네트워크가 끊겼다면 휴대전화 화면이나 ADB로 앱을 열어 host-only 정책을
다시 적용합니다.

## USB가 예상과 다르게 보입니다

**끄기**는 raw USBFS(`/dev/bus/usb`)와 문자 장치 major 189만 차단합니다. Android
커널이 감지한 USB 토폴로지는 공유 `/sys`에서 보일 수 있고, 이미 커널 드라이버가
만든 다음 자원도 계속 보일 수 있습니다.

- 저장장치: `/dev/block/sd*`
- USB Ethernet: `ip link`의 네트워크 interface
- serial: `/dev/ttyUSB*`, `/dev/ttyACM*`
- 영상·오디오·입력: `/dev/video*`, `/dev/snd/*`, `/dev/input/*`

따라서 끄기 모드에서 `lsusb -t`에 장치 이름이 보이는 것만으로 raw passthrough가
열린 것은 아닙니다. 다음을 따로 확인합니다.

```sh
ls -l /dev/bus/usb/*/* 2>/dev/null
ls -l /dev/block/sd* /dev/ttyUSB* /dev/ttyACM* /dev/video* 2>/dev/null
ip -brief link
```

구형 커널에서 `lsusb -t`가 `rx_lanes`/`tx_lanes` 파일 없음 경고를 내면 최신
커널용 usbutils가 없는 sysfs 속성을 조회한 것입니다. 앱 정책을 적용하면 설치되는
관리형 wrapper가 해당 `ENOENT` 경고만 숨깁니다.

`/dev/sdX1 is not a valid block device`가 나오면 이름만 보고 추측하지 말고 실제
major/minor와 파일 형식을 확인합니다.

```sh
lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINTS
stat -c '%F %t:%T %n' /dev/sdX /dev/sdX1 2>/dev/null
cat /proc/partitions
blkid /dev/sdX* 2>/dev/null
```

Android와 Debian에서 같은 파일시스템을 동시에 mount하지 마세요. 독점 모드는
정확한 `VID:PID`만 사용하고, 실패 후 driver가 복구되지 않으면 장치를 뽑았다가
다시 연결하거나 기기를 재부팅합니다.

## 하드웨어 영상 코덱 또는 FFmpeg가 실패합니다

먼저 기능을 켜고 BFU 런타임을 저장한 뒤 **Debian 13 systemd + SSH 구성**을 다시
실행합니다.

```sh
command -v dawnshell-codec dawnshell-ffmpeg dawnshell-hwencode
sudo dawnshell-codec health --format json
dawnshell-ffmpeg-integration status
```

정상 health에는 `worker_state=ready`,
`transport=inherited_memfd_eventfd`, `public_listener=false`,
`software_fallback=false`가 있습니다.

| 증상 | 원인과 조치 |
| --- | --- |
| `CANNOT LINK ... libandroidicu.so not found` | 오래된 worker/runtime입니다. 최신 APK에서 BFU 런타임 배치와 Debian 구성을 다시 실행합니다. |
| `Connection refused` | 폐기된 socket 기반 도구가 rootfs에 남아 있습니다. 현재 APK로 Debian 구성을 다시 실행합니다. |
| `Broken pipe` | worker가 먼저 종료됐습니다. 명령 위쪽의 worker/linker 오류와 전체 stderr를 확인합니다. |
| `hardware bridge required but unavailable` | 명령이 지원 범위 밖이거나 worker가 준비되지 않았습니다. 아래 `plan-ffmpeg`로 이유를 확인합니다. |
| BFU에서만 실패 | Android media service가 아직 준비되지 않은 플랫폼일 수 있습니다. 잠금 해제 뒤 같은 명령을 비교합니다. Debian과 SSH는 계속 살아 있어야 합니다. |

```sh
/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg \
  -i input.mp4 -c:v h264_mediacodec output.mp4
```

필터, CRF/preset, 복수 입출력 등은 자동 하드웨어 범위 밖입니다. 명령에
`mediacodec`을 직접 적으면 소프트웨어로 조용히 전환하지 않고 실패하는 것이
정상입니다. 자세한 범위는 [FFmpeg 하드웨어 코덱 사용법](ffmpeg-hardware-codec.ko.md)을
참고하세요.

## `gsmi`에서 GPU 사용률이 0%입니다

H.264/HEVC MediaCodec은 일반적으로 3D GPU가 아니라 전용 영상 엔진을 사용합니다.
따라서 `3D utilization=0%`와 `Codec activity=active`가 동시에 나올 수 있습니다.

```sh
gsmi --loop 1
```

커널이 VPU busy counter를 공개하지 않으면 `Codec utilization=unavailable`이
정확한 결과입니다. DawnShell은 추정 퍼센트를 만들지 않습니다. 자세한 해석은
[`gsmi` 문서](gpu-status-tool.ko.md)를 참고하세요.

## 로그를 안전하게 공유하는 방법

문제와 관련된 로그 하나를 전체 복사하고 다음 정보를 덧붙입니다.

- DawnShell 버전과 설치 경로(정식 Release 또는 CI debug)
- Android 버전과 CPU ABI
- BFU 또는 AFU 중 어느 상태였는지
- 재현한 버튼/명령과 선택한 cgroup, Docker, USB, 코덱 옵션
- 기대한 결과와 실제 결과

다음 내용은 삭제합니다.

- `-----BEGIN OPENSSH PRIVATE KEY-----`부터 끝까지
- 비밀번호, API token, VPN auth key
- 공개하고 싶지 않은 IP, 호스트 이름, 사용자 파일 경로
