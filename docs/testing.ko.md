# DawnShell 테스트 방법

[English](testing.md) · [쉬운 용어집](glossary.ko.md)

이 문서는 실제 Android 기기에서 DawnShell의 설치, BFU 부팅, SSH, 잠금 해제
연속성과 안전한 종료를 확인하는 방법을 설명합니다.

## 준비

- 정식 또는 시험할 APK를 설치합니다.
- Magisk root를 영구 허용합니다.
- Debian 설치와 systemd + SSH 구성을 완료합니다.
- SSH 개인 키를 별도 기기에 내보냅니다.
- 다른 복구 방법을 준비합니다.
- BFU(Before First Unlock)와 AFU(After First Unlock)의 차이를
  [용어집](glossary.ko.md)에서 확인합니다.

ADB(Android Debug Bridge)는 잠금 해제 뒤 진단에 사용할 수 있지만 BFU SSH 성공
조건은 아닙니다. [Google ADB 문서](https://developer.android.com/tools/adb)도
참고할 수 있습니다.

## 1. 설치 상태

앱의 **상태**를 눌러 다음 항목을 확인합니다.

- rootfs가 준비되었습니다.
- systemd PID 1이 실행됩니다.
- D-Bus가 동작합니다.
- `ssh.service`가 `active`입니다.
- TCP 22가 listen 상태입니다.
- cgroup health가 정상입니다.

앱 패키지와 target SDK를 ADB로 확인하려면 다음 명령을 사용할 수 있습니다.

```sh
adb shell dumpsys package me.aroxu.dawnshell
```

manifest에는 Direct Boot receiver와 service가 있어야 합니다. Android가 요구하는
`directBootAware` 동작은 [Google 공식 문서](https://developer.android.com/privacy-and-security/direct-boot#request_access)에
설명되어 있습니다.

## 2. DE와 CE 격리

재부팅 전 앱의 BFU 런타임 배치를 완료합니다. 재부팅 뒤 잠금을 풀기 전에는 앱
CE(Credential Encrypted) sentinel을 읽을 수 없어야 합니다. 정상 진단 표식은
다음과 같습니다.

```text
BFU_APP_CE_ISOLATED
```

다음 표식은 ROM이 잠금 전 앱 CE를 노출했다는 뜻이며 기본 정책에서는 부팅을
차단해야 합니다.

```text
BFU_APP_CE_CONTENT_ACCESSIBLE
```

DE와 CE의 공식 차이는 [Google Direct Boot 저장소 설명](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted)에서
확인할 수 있습니다.

## 3. 첫 BFU 부팅

1. 휴대폰을 재부팅합니다.
2. PIN, 패턴 또는 비밀번호를 입력하지 않습니다.
3. 다른 기기에서 SSH로 접속합니다.

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

접속 후 다음 명령을 실행합니다.

```sh
id
cat /proc/1/comm
systemctl is-active ssh.service
ip addr
uptime
```

정상 결과는 다음과 같습니다.

- `id`는 `debian` 사용자를 표시합니다.
- `/proc/1/comm`은 `systemd`입니다.
- SSH 서비스는 `active`입니다.
- Android가 준비한 네트워크 인터페이스가 보입니다.

## 4. 첫 잠금 해제

BFU SSH 연결을 유지한 채 Android 잠금을 풉니다.

- 기존 SSH 연결이 끊기지 않아야 합니다.
- Debian PID 1이 바뀌지 않아야 합니다.
- 새 systemd 인스턴스가 중복으로 생기지 않아야 합니다.
- 로그에 `USER_UNLOCKED`가 기록되어야 합니다.

화면을 다시 잠그는 것은 새 BFU가 아닙니다. 재부팅 뒤 첫 잠금 해제 전만 BFU입니다.

## 5. 네트워크 지연과 변경

부팅 직후 Wi-Fi가 아직 연결되지 않은 상태에서도 SSH 서버는 TCP 22에서 계속
대기해야 합니다. Android가 나중에 주소를 할당하면 Debian을 재시작하지 않고
접속할 수 있어야 합니다.

가능하면 다음 전환을 시험합니다.

- Wi-Fi 연결과 해제
- 모바일 데이터 연결
- USB Ethernet 연결과 해제
- VPN 또는 Tailscale 연결

### USB 패스스루 정책

USB 패스스루를 끄고 Debian을 재시작한 뒤 raw usbfs가 보이지 않고 lifecycle
로그에 `policy=off` 및 major 189 차단이 기록되는지 확인합니다. 직접 모드를
선택하고 재시작한 다음, 알고 있는 USB 호스트 장치를 연결해
`/dev/bus/usb/BBB/DDD` 노드가 나타나면서 Android 드라이버는 계속 연결되어
있는지 확인합니다. Debian을 재시작하지 않고 분리·재연결합니다.

독점 모드는 고장 나도 되는 시험 장치의 정확한 `VID:PID`를 입력하고, 해당 장치와
무관한 ADB 또는 물리 복구 수단을 준비한 상태에서 검사합니다. 로그의
`action=unbind`, libusb claim 성공, 무관한 장치의 드라이버 유지, 정상 Debian
종료 뒤 `action=restore`와 드라이버 복원을 확인합니다. hot-plug도 반복합니다.
USB 저장장치는 Android와 Debian 중 한쪽에서만 마운트합니다.

## 6. 반복 부팅

기본 회귀 시험은 cold boot 5회입니다.

매 회차 다음 순서를 반복합니다.

1. 재부팅합니다.
2. 잠금을 풀지 않고 SSH에 접속합니다.
3. systemd PID 1과 SSH를 확인합니다.
4. 잠금을 풉니다.
5. 기존 연결과 PID가 유지되는지 확인합니다.
6. 중복 supervisor와 남은 프로세스가 없는지 확인합니다.

자동 시험 스크립트는 다음과 같이 실행할 수 있습니다.

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/dawnshell-ed25519 \
./scripts/test-final-bfu.sh
```

수정 ROM이 BFU에서 앱 CE를 노출한다는 사실을 이미 확인했고 예외 정책을
시험한다면 `BFU_EXPECT_CE_READABLE_OVERRIDE=1`을 추가합니다. 일반 기기에서는
사용하지 않습니다.

## 7. 종료와 재시작

앱의 **중지**를 누른 뒤 다음을 확인합니다.

- `ssh.service`가 종료됩니다.
- systemd와 자식 프로세스가 남지 않습니다.
- 전용 마운트와 cgroup 하위 트리가 정리됩니다.
- Android 네트워크는 계속 동작합니다.

그다음 **시작**과 **재시작**을 각각 시험합니다. 매번 systemd PID 1이 하나만
있어야 합니다.

## 8. Android 재부팅 bridge

Debian root 셸에서 먼저 다음 명령을 실행합니다.

```sh
reboot --check
```

검사가 성공한 뒤 저장 중인 작업을 끝내고 다음 명령을 실행합니다.

```sh
reboot now
```

Android 전체가 재부팅되어야 합니다. 반대로 `systemctl reboot`는 기기 전체를
재부팅하지 않아야 합니다.

## 9. Docker

기본 host-network-only 정책에서는 다음 방식으로 컨테이너를 실행합니다.

```sh
docker run --rm --network host hello-world
```

bridge 정책은 별도 복구 경로를 준비한 뒤에만 시험합니다. 적용 전후에 Android의
Wi-Fi, 모바일 데이터, USB Ethernet, VPN, Tailscale과 SSH가 유지되는지
확인합니다.

## 10. 하드웨어 영상 코덱

옵션을 켜고 **저장하고 하드웨어 코덱 검사**를 누른 뒤 전용 로그에서 다음을
확인합니다.

- `classification=platform_api29` 또는 구형 Android의 명시적 `heuristic_*`
- `avc_decoder=created(...)` 또는 `avc_encoder=created(...)`
- 선택된 이름이 `OMX.google.*`, `c2.android.*` 또는 `.secure`가 아님
- 실패해도 Debian PID 1과 SSH가 유지됨

그다음 재부팅하고 잠금을 해제하지 않은 채 동일한 결과가 기록되는지 확인합니다.
최초 잠금 해제 뒤 `:codec` 프로세스와 Debian이 모두 유지되어야 합니다. BFU에서
미디어 서비스가 없는 ROM은 `UNAVAILABLE`일 수 있지만 소프트웨어 코덱 성공으로
표시되어서는 안 됩니다. AFU 결과는 반드시 `user_unlocked=true`로 구분해 BFU
증거로 사용하지 않습니다.

실제 frame 경로는 Debian에서 `dawnshell-codec-self-test`를 실행해 decode checksum,
encode keyframe/PTS/EOS, FFmpeg 재검증과 Surface zero-copy 통계를 확인합니다.
`dawnshell-codec health --format json`은 `broker_state=listening`과 session 정리를,
`dawnshell-codec negative-test`는 잘못된 요청 뒤 broker 생존을 확인합니다. 최종 5회
시험은 `BFU_REQUIRE_HARDWARE_CODEC=1 BFU_CYCLES=5 scripts/test-final-bfu.sh`로
잠금 해제 전후에 동일한 검사를 실행합니다.

앱의 **단기 성능·품질·오류 회귀 검사**는 다음을 한 번에 수행합니다.

- 720p 30-frame decode checksum과 정확한 PTS
- 공유 메모리와 강제 socket fallback의 실제 byte counter 및 process CPU 시간 비교
- B-frame MP4 hardware decode와 출력 PTS reorder 검증
- 1080p software/hardware decode checksum 및 client+broker CPU 기준선 기록
- 1080p hardware encode 결과의 frame 수, PSNR 30 dB 및 SSIM 0.90 하한
- 1080p30 60-frame Surface transcode가 2초 이내인지 확인
- HEVC MP4→AVC Surface transcode 60-frame 확인
- 첫 keyframe, EOS, FFmpeg decode, `cpu_yuv_frames=0`
- decoder 5회 및 Surface transcoder 2회 비정상 client 종료 뒤 자원 회수
- H.264/HEVC 설정 누락·절단, framing/EOS 오류, idle peer 및 느린 출력 client의
  bounded backpressure 격리와 동시 2-session 조합
- 자체 `:codec` PID 강제 종료 뒤 30초 안에 새 PID와 빈 session 상태로 복구

**장시간 하드웨어 코덱 검사**는 5개 workload를 각각 10분 실행하므로 약 50분이
걸립니다. 앱에서 시작한 뒤 전용 로그 화면을 열 수 있고 **즉시 중지**로 systemd
service를 바로 중단할 수 있습니다. 결과는 `/var/log/dawnshell/codec-tests/`에
client user/system CPU와 최대 RSS, broker CPU/RSS/FD/heap, queue timeout/high-water,
battery temperature와 thermal 상태로 남습니다. 첫 실기기 결과가 쌓이기 전에는
software 대비 CPU 감소율을 기록하되 임의의 수치로 실패시키지 않습니다.

최종 5회 시험에는 다음 환경 변수를 함께 사용합니다.

```sh
BFU_REQUIRE_HARDWARE_CODEC=1 \
BFU_REQUIRE_CODEC_PERFORMANCE=1 \
BFU_CYCLES=5 \
scripts/test-final-bfu.sh
```

## 11. 삭제

테스트 데이터가 필요하지 않을 때만 rootfs 삭제를 시험합니다.

1. 서버를 중지합니다.
2. 필요한 데이터를 백업합니다.
3. 위험 구역의 삭제 흐름을 완료합니다.
4. `DEBIAN_ROOTFS_REMOVE_SUCCEEDED`를 확인합니다.
5. `/data/local/debian`만 삭제되고 앱 설정과 로그는 남았는지 확인합니다.

## 통과 기준

- PIN 입력 전 SSH 접속이 됩니다.
- 앱 CE가 BFU에서 닫혀 있습니다. 예외는 명시적으로 수락한 ROM만 허용합니다.
- systemd와 SSH는 첫 잠금 해제 뒤에도 같은 인스턴스로 유지됩니다.
- 5회 반복에서 중복 프로세스나 누적 마운트가 없습니다.
- 네트워크가 늦게 연결되어도 SSH 서버가 살아 있습니다.
- 종료와 삭제가 검증된 대상만 정리합니다.
