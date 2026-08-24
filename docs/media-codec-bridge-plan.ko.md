# DawnShell 하드웨어 영상 코덱 브리지

이 문서는 Android의 하드웨어 영상 코덱을 Debian 13에서 안전하게 사용하는 기능의
제품 범위와 단계별 통과 조건을 기록합니다. 이 기능은 OpenGL, Vulkan 또는 범용
GPU 패스스루가 아닙니다. Android `MediaCodec`/`AMediaCodec`과 기기의 전용 영상
코덱 블록을 사용하는 로컬 브리지입니다.

## 목표 구조

```text
Debian 프로그램 / FFmpeg adapter
  → versioned local Unix socket protocol
  → bounded shared-memory frame/packet queue
  → isolated DawnShell Android codec process
  → public MediaCodec / AMediaCodec API
  → vendor Codec2 또는 OMX hardware codec
```

코덱 오류는 Debian systemd, SSH와 Direct Boot supervisor를 종료시키지 않아야
합니다. `USER_UNLOCKED`가 발생해도 실행 중인 broker는 중지하지 않습니다.

## 지원 범위

- H.264/AVC decode와 encode를 우선합니다.
- capability가 확인된 기기에서는 HEVC/H.265도 제공합니다.
- container demux/mux는 Debian FFmpeg가 담당합니다.
- 실제 codec 이름, hardware/software/vendor 판정과 판정 근거를 공개합니다.
- secure/DRM codec과 외부 네트워크 API는 지원하지 않습니다.
- software fallback은 별도 명시 옵션이 없는 한 금지합니다.
- `armeabi-v7a`, `arm64-v8a`, `x86_64`를 지원합니다.

## Android 버전 호환성

Android 10(API 29) 이상은 `MediaCodecInfo.isHardwareAccelerated()`,
`isSoftwareOnly()`, `isVendor()`와 canonical name을 사용합니다. Android 7~9는
알려진 platform software 및 vendor codec 이름만 보수적으로 분류합니다. 알 수
없는 이름은 하드웨어로 취급하지 않으며 모든 결과에 heuristic임을 표시합니다.

커널 버전이나 제조사 문자열만으로 지원 여부를 추측하지 않습니다. 각 부팅에서
Android media service와 실제 codec instance 생성을 제한 시간 안에 검사합니다.

## 수명 주기

1. `LOCKED_BOOT_COMPLETED` 뒤 DE 설정을 읽습니다.
2. 옵션이 켜진 경우 별도 `:codec` 프로세스를 포그라운드로 시작합니다.
3. media service 준비를 제한된 횟수와 backoff로 검사합니다.
4. hardware AVC/HEVC instance를 생성하고 backend를 기록합니다.
5. 실패하면 codec 기능만 비활성화하고 Debian과 SSH는 유지합니다.
6. `USER_UNLOCKED`에서 broker를 유지하고 capability를 다시 확인합니다.
7. 사용자가 옵션을 끄거나 Android가 종료될 때 session과 process를 정리합니다.

## IPC와 보안

최종 제어 채널은 외부 TCP가 아닌 local Unix domain socket을 사용합니다. protocol은
magic, version, message type, session ID, payload length를 갖는 binary framing으로
정의합니다. 알 수 없는 version과 과도한 길이는 fail-closed합니다.

큰 payload는 고정 상한의 shared memory와 `SCM_RIGHTS`를 사용합니다. session 수,
해상도, bitrate, queue 깊이와 총 메모리를 제한하고 backpressure를 적용합니다.
DE 로그에는 codec 이름, capability와 오류만 저장하고 frame, bitstream, 사용자
파일 경로와 인증 정보를 저장하지 않습니다. 신뢰하지 않는 입력의 자동 처리는
기본 비활성입니다.

## 단계별 통과 조건

### M0 — capability probe

- AFU와 BFU에서 video codec 목록을 JSON으로 기록합니다.
- hardware/software/vendor 판정과 근거를 기록합니다.
- hardware AVC encoder 또는 decoder를 생성하고 즉시 해제합니다.

통과: BFU에서 hardware AVC instance 하나 이상 생성.

### M1 — broker probe

- 별도 Android process에서 probe를 실행합니다.
- BFU media service 지연을 bounded retry합니다.
- 오류가 Debian/SSH에 전파되지 않음을 확인합니다.

통과: cold boot와 AFU에서 같은 vendor backend 확인.

### M2 — local protocol

- capability, session create/close, input/output, flush, EOS를 구현합니다.
- peer credential, socket mode와 malformed message를 검증합니다.
- Debian CLI `dawnshell-codec`을 세 architecture로 제공합니다.

통과: Debian client가 BFU에서 hardware session을 생성.

### M3 — H.264 decode

- 고정된 공개 Annex-B test vector를 ByteBuffer/YUV 경로로 decode합니다.
- software baseline의 frame checksum, PTS와 frame 수를 비교합니다.

통과: 720p sample의 모든 frame과 timestamp 일치.

첫 회귀 벡터는 프로젝트가 CC0-1.0으로 제공하는 128×96, 10 fps, 10-frame
Constrained Baseline Annex-B 파일입니다. 다음 설정으로 생성해 저장소에 고정했습니다.

```sh
ffmpeg -f lavfi -i 'testsrc2=size=128x96:rate=10:duration=1' \
  -pix_fmt yuv420p -c:v libx264 -profile:v baseline -level:v 3.0 \
  -preset veryslow -crf 18 \
  -x264-params 'keyint=10:min-keyint=10:scenecut=0:bframes=0:aud=1:repeat-headers=1' \
  -an -f h264 avc-baseline-128x96-10fps.h264
```

`dawnshell-codec-self-test`는 각 AUD access unit에 결정적인 PTS를 부여하고, Android
broker가 `Image` plane의 row/pixel stride와 crop을 정규화한 I420 frame 10개를
검사합니다. frame 수와 PTS가 일치한 뒤 software decode 기준 SHA-256
`777feb39bd92b899fc9cf7c184396e3ecec4fdbcd7a582fc560fc37011f18053`을 비교합니다.

계획의 720p 통과 조건은 별도 1280×720, 30 fps, 30-frame vector와 software I420
기준 SHA-256 `7ff494db80cf8a311468f9638384d3d7a7bd320b5b831110076b7c80979af26f`를
사용합니다. 같은 입력을 기본 shared-memory와 강제 socket fallback으로 각각
decode해 frame/PTS/checksum이 같고 두 transport가 실제로 사용됐는지 비교합니다.

### M4 — H.264 encode

- 고정 YUV pattern을 hardware encoder로 처리합니다.
- FFmpeg software decoder로 출력 bitstream과 PTS/EOS를 검증합니다.

통과: 유효한 H.264 출력과 실시간 이상의 처리 속도.

`dawnshell-codec encode-test`는 결정적인 I420 pattern과 PTS를 생성하고 codec이
선택한 planar/semi-planar ByteBuffer layout으로 변환합니다. frame 수, PTS, EOS,
출력 byte 수와 wall-clock 처리 시간을 검사한 후 `dawnshell-codec-self-test`가
Debian FFmpeg로 출력 Annex-B를 다시 decode해 10 frame임을 확인합니다.

### M5 — FFmpeg pipeline

- Debian FFmpeg demux/mux와 독립 client를 연결합니다.
- pipe와 shared-memory path의 성능 및 CPU 사용률을 비교합니다.

통과: 일반 MP4 입력을 hardware decode 또는 encode 경로로 처리.

`dawnshell-ffmpeg`는 기존 FFmpeg 명령줄을 그대로 받아, bridge가 동일하게
재현할 수 있는 경우에만 hardware 경로로 보내고 나머지는 실제 FFmpeg에
위임합니다. filter, x264 전용 옵션, 다중 입력, stream copy와 미지원 codec은
software로 유지하므로 사용자가 요청한 동작이 조용히 달라지지 않습니다.
`/usr/local/bin/ffmpeg` symlink를 만들면 Jellyfin 같은 기존 프로그램도 수정
없이 같은 경로를 사용합니다. `DAWNSHELL_FFMPEG_BRIDGE`로 `auto`, `off`,
`require`를 선택할 수 있으며 `require`는 software fallback을 오류로 만듭니다.

`dawnshell-codec-performance-test`는 720p 결과를 한 번에 하나씩 `/run`에 기록해
64 MiB tmpfs 상한을 지키고, session의 wall time과 codec broker process CPU time,
socket/shared-memory byte 수를 함께 보고합니다.

### M6 — zero-copy transcode

- decoder output Surface와 encoder input Surface를 연결합니다.
- H.265→H.264 또는 H.264 bitrate 변경을 시험합니다.

통과: 불필요한 CPU frame copy 없이 1080p 실시간 처리.

고정 1920×1080, 30 fps, 60-frame AVC vector를 AVC→AVC Surface session에 넣습니다.
출력 60 frame의 정확한 PTS, 첫 keyframe, EOS와 FFmpeg decode를 확인하고 session
runtime이 2,000 ms 이하인지 검사합니다. `surface_frames=60`,
`cpu_yuv_frames=0`, 오류 및 drop 0이어야 통과합니다.

### M7 — BFU 회귀 시험

- cold boot 5회, unlock 유지, stop/restart와 network 지연을 시험합니다.
- 중복 process, socket, shared memory와 session 누수를 확인합니다.

통과: 5회 모두 BFU self-test 성공 및 Debian/SSH 영향 없음.

단기 성능 검사는 shared/socket decode, B-frame MP4 decode, 1080p CPU 기준선,
hardware encode 품질, AVC/HEVC Surface transcode와 decoder peer 강제 종료 5회,
Surface transcoder peer 강제 종료 2회를 수행합니다. 전후 broker PID/uptime이 유지되고
생성·종료 session delta가 모두 14이며 active session/transcoder가 0인지 확인합니다.

## 현재 상태

M0~M6 코드 경로가 구현되어 있습니다. 별도 `:codec` 프로세스의 versioned abstract
Unix socket broker, strict `SO_PEERCRED` UID 0 인증, 동시 peer 4개 상한, bounded
framing, peer 종료 시 session
release와 `armeabi-v7a`/`arm64-v8a`/`x86_64` 정적 client를 제공합니다. 64 KiB 이상
payload는 `memfd`/`SCM_RIGHTS`를 먼저 사용하고 안전한 socket copy로 폴백합니다.

고정 H.264 vector의 Image→I420 checksum decode, 결정적 I420 hardware AVC/HEVC
encode, H.264/HEVC FFmpeg demux/mux wrapper, H.264/HEVC→H.264 Surface transcode가
구현됐습니다. encode와
transcode는 keyframe을 요청하고 첫 frame flag를 확인합니다. broker health 및 session
통계로 frame/EOS/error/shared-memory와 Surface 경로의 `cpu_yuv_frames=0`을 검사하며
잘못된 요청 뒤에도 broker가 응답하는지 확인합니다.

720p shared-memory/socket 비교, B-frame MP4 및 HEVC container, 1080p30 CPU 기준선,
hardware encode PSNR/SSIM, 실시간 Surface transcode와 peer 강제 종료 자원 정리는
별도 성능 검사 및 앱 버튼으로 구현되어 있습니다. 큰 raw frame은 `/run`에 복제하지
않고 FFmpeg↔adapter↔client 파이프로 전달합니다. 네 성능 vector는
`scripts/generate-codec-performance-vectors.sh`로 재생성할 수 있으며 프로젝트가
CC0-1.0으로 제공합니다.

오류 회귀는 protocol magic/version/header/type/길이, H.264/HEVC 설정 누락과 절단,
framing 길이 불일치, EOS 중복, EOS 이후 입력, encoder PTS 역행, peer 상한,
범위 초과와 비정상 peer 종료를 session 단위로 격리합니다. 끊어진 socket의
`SIGPIPE`도 process 종료 대신 오류로 처리합니다. 동시성 회귀는
decoder+encoder, decoder 2개, transcoder+decoder 조합을 시도하며 vendor resource
한계는 명시적 skip으로 기록하되 최소 한 조합은 성공해야 합니다.

앱에서 시작하는 장시간 검사는 720p decode, 1080p decode/encode, AVC/HEVC transcode를
각 10분씩 실행합니다. client user/system CPU 및 최대 RSS, broker CPU/RSS/FD/heap,
queue timeout/high-water, queue/dequeue 평균·최대 호출 latency, 실제 encode bitrate,
battery temperature와 Android thermal 상태를 증거 디렉터리에 기록합니다. software
대비 CPU 감소율과 bitrate 편차는 첫 실기기 결과를 수집하되 아직 임의의 수치
threshold로 통과/실패시키지 않습니다.

제공된 Android 16 AFU 로그에서는 vendor AVC/HEVC encoder와 decoder 인스턴스 생성이
모두 성공했습니다(확인된 backend: Exynos). 로그가 `user_unlocked=true`이므로
BFU M0 판정은 아직 아니며,
BFU backend/session, 720p·1080p 성능과 M7 5회 cold-boot 회귀는 마지막 일괄 실기기
시험에서 검증합니다.

성능 vector 생성의 핵심 설정은 다음과 같습니다. 재현성을 위해 x264 assembly와
병렬 lookahead를 끄고 한 thread로 고정했습니다.

```sh
scripts/generate-codec-performance-vectors.sh
```
