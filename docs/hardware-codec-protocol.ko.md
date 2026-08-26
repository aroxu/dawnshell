# DawnShell NDK 하드웨어 코덱 worker 프로토콜 v1

[English](hardware-codec-protocol.md) · [문서 홈](README.ko.md) ·
[구현 결정 기록](media-codec-bridge-plan.ko.md)

이 문서는 Debian 13의 `dawnshell-codec`과 Android bionic
`dawnshell-codec-worker` 사이의 내부 프로토콜을 설명합니다. 이 기능은 GPU
패스스루가 아니라 Android NDK `AMediaCodec`을 이용한 AVC/HEVC 영상
디코드·인코드·Surface 트랜스코드입니다.

## 프로세스와 전송 구조

명령을 실행할 때마다 다음 구조가 한 번 만들어집니다.

```text
Debian glibc 프로그램/FFmpeg wrapper
  └─ 정적 Android ELF dawnshell-codec (부모)
       ├─ memfd 1개: control page + request slot + response slot
       ├─ eventfd 1개: request 알림
       ├─ eventfd 1개: response 알림
       └─ fork/exec
            └─ bionic dawnshell-codec-worker
                 └─ NDK AMediaCodec / AImageReader / ANativeWindow
```

- listening socket, TCP port, filesystem socket, Binder service 등록이 없습니다.
- `sendmsg`/`recvmsg`와 `SCM_RIGHTS` descriptor 전달을 사용하지 않습니다.
- 부모가 만든 descriptor를 고정 FD 3, 4, 5로 자식에게 직접 상속합니다.
- worker에는 `PR_SET_PDEATHSIG(SIGTERM)`을 설정합니다. 부모가 사라지면 worker도
  종료되고 모든 코덱 session을 release합니다.
- worker는 상주 daemon이 아닙니다. CLI 명령 하나에 private worker 하나가
  대응합니다. 명령이 끝나면 정상 종료합니다.
- request는 한 번에 하나만 outstanding 상태가 될 수 있어 queue가 무한히 커지지
  않습니다.

공유 mapping은 약 16 MiB이며 control page 4 KiB, request/response slot은 각각
`32 + 8 MiB`입니다. 전체 frame을 복사하는 byte-buffer decode/encode는 이 slot을
사용합니다. Surface transcode에서는 압축 packet만 slot을 통과하고 full-size YUV는
Android Surface 안에 남습니다.

## chroot에서 Android runtime을 실행하는 방법

`dawnshell-codec`은 정적 실행 파일이고 worker는 `/system/bin/linker[64]`를 사용하는
동적 bionic 실행 파일입니다. DawnShell의 private mount namespace는 다음 Android
runtime tree만 Debian에 읽기 전용으로 노출합니다.

- `/system`
- `/apex`
- `/linkerconfig`(기기에 존재할 때)

mount에는 read-only, `nosuid`, `nodev`를 적용하되 Android linker 실행을 위해
`noexec`는 적용하지 않습니다. 일반 앱 CE, DawnShell 앱 데이터, Android의 다른
쓰기 가능한 데이터 tree는 코덱을 위해 bind하지 않습니다.

정적 client는 worker를 `exec`하기 전에 상속된 `LD_PRELOAD`, `LD_AUDIT`,
`LD_DEBUG`, `LD_CONFIG_FILE`, `LD_LIBRARY_PATH`를 제거합니다. Android의 읽기 전용
ICU APEX가 있으면 ABI에 맞는 `/apex/com.android.i18n/lib[64]` 디렉터리만
`LD_LIBRARY_PATH`로 설정합니다. 직접 실행한 bionic ELF에는 앱 class-loader
namespace가 없기 때문에 일부 Android linker 설정은 `/system/lib[64]/libmedia.so`는
찾아도 전이 의존성인 `libandroidicu.so`를 찾지 못합니다. 이 제한된 경로가 해당
문제를 해결합니다. APEX가 없는 구형 Android에서는 override를 설정하지 않아 기존
legacy linker 검색을 그대로 사용합니다.

## transport control page

control page에는 다음 값이 있습니다.

- magic `DSCW` (`0x44534357`), transport version `1`
- mapping/slot 크기
- 부모/worker PID
- `WORKER_READY`, `WORKER_FAILED`, `SHUTDOWN` flag
- request/response sequence와 byte 수

부모는 request slot을 쓴 뒤 release store로 sequence를 게시하고 request eventfd를
증가시킵니다. worker는 처리 후 response slot과 sequence를 게시하고 response
eventfd를 증가시킵니다. 부모는 sequence, protocol header, 전체 길이를 모두 다시
검증합니다. 시작 handshake는 10초, 일반 RPC는 35초 상한입니다.

## 고정 protocol header

slot 내부 protocol 정수는 network byte order(big-endian)입니다. 요청과 응답 헤더는
32바이트입니다.

| offset | size | 값 |
| --- | ---: | --- |
| 0 | 4 | magic `DSCB` (`0x44534342`) |
| 4 | 2 | protocol version `1` |
| 6 | 2 | message type, 응답은 `type | 0x8000` |
| 8 | 4 | flags, v1에서는 0 |
| 12 | 8 | session ID, create 요청은 0 |
| 20 | 4 | payload length |
| 24 | 4 | 0이 아닌 request ID |
| 28 | 4 | 요청은 0, 응답은 signed status |

잘못된 magic/version/flags/request ID, 길이 불일치, 8 MiB 상한 초과는 fail-closed로
처리합니다. 한 worker에서 동시에 유지할 수 있는 session은 2개입니다.

## message

- `HELLO(1)`: protocol, `transport=inherited_memfd_eventfd`, worker 종류와
  `public_listener=false`, `descriptor_transfer=false`를 반환합니다.
- `CAPABILITIES(2)`: worker 기능과 AVC/HEVC 지원 범위를 반환합니다.
- `CREATE(3)`: byte-buffer decoder/encoder를 생성합니다.
- `INPUT(4)`: PTS, flags, packet 또는 I420 frame을 queue합니다.
- `OUTPUT(5)`: bounded timeout으로 output을 dequeue합니다. decoder의
  `YUV_420_888` plane은 crop/row stride/pixel stride를 반영해 packed I420으로
  정규화합니다.
- `FLUSH(6)`, `EOS(7)`, `CLOSE(8)`: session 상태를 제어합니다.
- `INPUT_SHARED_MEMORY(9)`, `OUTPUT_SHARED_MEMORY(10)`: 과거 descriptor 전달
  protocol 번호를 충돌 방지용으로 예약합니다. 현재 worker는 명시적으로 거부합니다.
- `CREATE_TRANSCODER(11)`: decoder output Surface를 encoder input Surface에 직접
  연결합니다.
- `REQUEST_KEYFRAME(12)`: encoder sync frame을 요청합니다.
- `HEALTH(13)`: 해당 private worker의 PID, uptime, active session, 요청/오류 수를
  반환합니다. 명령마다 worker가 새로 생기므로 다른 명령의 누적 상태가 아닙니다.
- `SESSION_STATS(14)`: frame/byte/EOS/error, call latency,
  `media_transport=inherited_memfd_eventfd` 및 Surface/CPU YUV frame 수를 반환합니다.

## 하드웨어 코덱 선택

software codec으로 조용히 폴백하지 않습니다.

1. 최신 Android에서는 `AMediaCodecStore` metadata로 hardware codec을 찾습니다.
2. API가 없거나 결과가 부족하면 검증된 platform component 이름을 보수적으로
   사용합니다.
3. 현재 알려진 이름에는 Exynos(`OMX.Exynos`, `OMX.SEC`, `c2.exynos`)와
   Qualcomm(`OMX.qcom`, `c2.qti`) 계열이 포함됩니다.
4. `OMX.google`, `c2.android` 같은 software component는 선택하지 않습니다.
5. vendor codec 생성/configure/start가 실패하면 다음 hardware 후보를 시도하고,
   모두 실패하면 명령을 실패시킵니다.

이름 기반 판정은 구형 Android 호환용 보수적 fallback입니다. 실제 codec 지원 여부와
SELinux/media service 접근은 실기기 실행에서 최종 확인해야 합니다.

## CLI와 FFmpeg

```sh
sudo dawnshell-codec capabilities
sudo dawnshell-codec health --format json
sudo dawnshell-codec probe decode avc 1920 1080
sudo dawnshell-codec probe encode hevc 1920 1080
sudo dawnshell-codec-self-test
sudo dawnshell-codec-performance-test

sudo dawnshell-hwdecode input.mp4 output.i420
sudo dawnshell-hwencode input.mp4 output.mp4 4000000 avc
sudo dawnshell-hwencode input.mp4 output.hevc 8000000 hevc
sudo dawnshell-hwtranscode input.mp4 output.mp4 6000000
```

`pipe` record는 `pts_us:u64`, `flags:u32`, `length:u32`, `data` 순서의 big-endian
framing입니다. FFmpeg wrapper는 container demux/mux, bitstream filter와 audio 처리를
Debian FFmpeg에 맡기고 영상 codec 작업만 private NDK worker에 보냅니다.

## BFU와 AFU

- APK는 armhf/arm64/amd64에 대응하는 client와 worker를 DE에 provisioning합니다.
- Debian 구성 시 두 파일을 rootfs의 `/usr/local/bin`과 `/usr/local/libexec`에
  설치합니다.
- BFU/AFU 모두 동일한 on-demand worker 경로를 사용합니다.
- `USER_UNLOCKED`는 실행 중인 Debian/systemd를 중지하지 않습니다.
- worker 자체를 미리 상주시킬 필요가 없습니다. BFU에서 첫 codec 명령이 실행될 때
  생성됩니다.
- BFU 시점에 Android media service나 vendor codec이 아직 준비되지 않았으면 codec
  명령만 실패하며 Debian PID 1, SSH, 네트워크는 유지됩니다.

## 보안·격리 한계

- 이 경로는 앱의 Java 프로세스를 통하지 않으며 앱 UID 인증 socket도 없습니다.
- 관리되는 root 실행 경로만 지원합니다.
- memfd는 부모와 해당 자식에게만 상속하며 public 이름이 없습니다.
- worker는 Android media service와 통신하므로 Magisk SELinux domain과 ROM 정책의
  영향을 받습니다.
- Surface transcode는 full YUV copy를 피하지만 compressed packet과 control record는
  shared slot을 통과합니다.
- byte-buffer decode/encode는 MediaCodec buffer와 shared slot 사이에 한 번 이상
  복사하므로 완전한 zero-copy가 아닙니다.

## 검증 기준

호스트 빌드에서 확인하는 항목:

- armv7/arm64/x86_64 client와 worker의 `-Werror` 컴파일
- client가 정적 ELF이고 worker가 Android linker 및
  `libmediandk/libandroid/libdl/libc`만 요구하는지 확인
- Debian data path에 `AF_UNIX`, `sendmsg/recvmsg`, `SCM_RIGHTS`가 없는지 확인
- app Java socket broker/JNI library가 패키징되지 않는지 확인
- worker provisioning, read-only runtime mount, wrapper 문법 및 APK 빌드

실기기에서만 확인 가능한 마지막 항목:

- BFU/AFU 각각에서 bionic worker가 Android linker로 시작되는지
- Magisk/SELinux domain에서 media codec service 접근이 허용되는지
- 실제 Exynos/Qualcomm AVC·HEVC codec configure/queue/dequeue 결과
- 1080p decode/encode, Surface transcode, 장시간/동시 worker 안정성
