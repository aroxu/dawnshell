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

### M4 — H.264 encode

- 고정 YUV pattern을 hardware encoder로 처리합니다.
- FFmpeg software decoder로 출력 bitstream과 PTS/EOS를 검증합니다.

통과: 유효한 H.264 출력과 실시간 이상의 처리 속도.

### M5 — FFmpeg pipeline

- Debian FFmpeg demux/mux와 독립 client를 연결합니다.
- pipe와 shared-memory path의 성능 및 CPU 사용률을 비교합니다.

통과: 일반 MP4 입력을 hardware decode 또는 encode 경로로 처리.

### M6 — zero-copy transcode

- decoder output Surface와 encoder input Surface를 연결합니다.
- H.265→H.264 또는 H.264 bitrate 변경을 시험합니다.

통과: 불필요한 CPU frame copy 없이 1080p 실시간 처리.

### M7 — BFU 회귀 시험

- cold boot 5회, unlock 유지, stop/restart와 network 지연을 시험합니다.
- 중복 process, socket, shared memory와 session 누수를 확인합니다.

통과: 5회 모두 BFU self-test 성공 및 Debian/SSH 영향 없음.

## 현재 상태

M0/M1 앱 측 기반과 M2 코드 경로가 구현되어 있습니다. M2에는 별도 `:codec`
프로세스의 versioned abstract Unix socket broker, `SO_PEERCRED` root 인증, bounded
binary framing, 실제 hardware session create/input/output/flush/EOS/close, peer 종료
시 release, 그리고 `armeabi-v7a`/`arm64-v8a`/`x86_64` 정적 `dawnshell-codec` CLI가
포함됩니다. CLI는 Debian `/usr/local/bin`에 설치되며 length-framed pipe 경로를
제공합니다.

실기기 BFU backend와 session create 통과 조건은 마지막 일괄 기기 시험에서
검증합니다. M3 고정 H.264 vector 검증, shared-memory 전송, FFmpeg 통합과 zero-copy
경로는 아직 남아 있습니다.
