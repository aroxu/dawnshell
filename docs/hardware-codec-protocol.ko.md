# DawnShell 하드웨어 코덱 로컬 프로토콜 v1

`dawnshell-codec`은 Debian chroot에서 Android의 별도 `:codec` 프로세스에
접속하는 정적 실행 파일입니다. 연결은 외부 TCP가 아닌 Android abstract Unix
socket `@dawnshell.codec.v1`을 사용합니다. 브로커는 `SO_PEERCRED`의 UID가 0인
Debian 프로세스만 허용합니다. 앱 내부 진단을 위해 동일 앱 UID도 허용하지만 다른
앱 UID는 요청 본문을 읽기 전에 연결을 끊습니다.

abstract socket에는 파일 권한 비트가 없으므로 `0600`인 것처럼 표현하지 않습니다.
대신 UID 검사를 접근 제어로 사용하며, DE의
`files/hardware-codec/broker.status`는 앱 소유자만 읽을 수 있게 저장합니다.

## 고정 헤더

모든 정수는 network byte order(big-endian)입니다. 요청과 응답 헤더는 32바이트입니다.

| 오프셋 | 크기 | 값 |
| --- | ---: | --- |
| 0 | 4 | magic `DSCB` (`0x44534342`) |
| 4 | 2 | protocol version `1` |
| 6 | 2 | message type; 응답은 `type | 0x8000` |
| 8 | 4 | flags; v1에서는 0 |
| 12 | 8 | session ID; create 요청은 0 |
| 20 | 4 | payload length |
| 24 | 4 | 0이 아닌 request ID |
| 28 | 4 | 요청은 0, 응답은 signed status |

잘못된 magic/version/flags/request ID, 알 수 없는 type, 길이 불일치와 상한 초과는
fail-closed합니다. control payload는 1 MiB, media payload는 8 MiB, 전체 session은
4개, peer당 session은 2개로 제한합니다. peer 연결은 30초 idle timeout을 둡니다.

## 메시지

- `HELLO(1)`: protocol과 제한을 JSON으로 반환합니다.
- `CAPABILITIES(2)`: BFU에서 probe한 하드웨어 codec JSON을 반환합니다.
- `CREATE(3)`: decode/encode, AVC/HEVC, 크기, FPS, bitrate, color format으로 실제
  하드웨어 `MediaCodec`을 configure/start하고 session ID를 반환합니다.
- `INPUT(4)`: PTS, flags와 한 packet/frame을 queue합니다.
- `OUTPUT(5)`: bounded timeout으로 output을 dequeue합니다. format change와
  backpressure는 별도 status로 반환합니다. decoder의 `YUV_420_888` Image plane은
  crop/row stride/pixel stride를 반영해 packed I420으로 정규화합니다.
- `FLUSH(6)`, `EOS(7)`, `CLOSE(8)`: session 상태를 제어합니다.
- `INPUT_SHARED_MEMORY(9)`, `OUTPUT_SHARED_MEMORY(10)`: 64 KiB 이상의 media를
  `memfd`와 `SCM_RIGHTS`로 전달합니다. metadata와 응답은 기존 socket에 남습니다.
- `CREATE_TRANSCODER(11)`: decoder output Surface를 encoder input Surface에 직접
  연결한 hardware transcode session을 만듭니다.
- `REQUEST_KEYFRAME(12)`: encoder에 다음 sync frame을 요청합니다.
- `HEALTH(13)`: broker uptime, peer/session 수, 오류 및 shared-memory byte 통계를
  JSON으로 반환합니다.
- `SESSION_STATS(14)`: session별 frame, EOS, 오류, transport와 CPU YUV copy 통계를
  JSON으로 반환합니다.

vendor codec 오류와 잘못된 client 입력은 해당 요청 또는 session에서만 실패하며
Debian PID 1, SSH, Direct Boot supervisor는 종료하지 않습니다. 연결이 끊기면 해당
peer가 만든 모든 session을 자동 release합니다.

## Debian CLI

```sh
dawnshell-codec capabilities
dawnshell-codec health --format json
dawnshell-codec negative-test
dawnshell-codec probe decode avc 128 128
dawnshell-codec pipe decode avc 1280 720 30 4000000 < packets.bin > frames.bin
dawnshell-codec-self-test
dawnshell-hwdecode input.mp4 output.mkv
dawnshell-hwdecode input.mp4 output.i420
dawnshell-hwencode input.mkv output.mp4 4000000
dawnshell-hwencode input.mkv output.h264
dawnshell-hwtranscode input-hevc.mkv output-h264.mp4 8000000
```

자체 검사는 고정 AVC decode의 frame/PTS/I420 checksum을 확인한 다음 고정 I420
pattern 10개를 hardware encoder로 처리합니다. encoder 출력의 frame/PTS/EOS와
실시간 이상 처리 속도를 확인하고 Debian FFmpeg가 결과 Annex-B bitstream 10개를
오류 없이 decode하는지 재검증합니다.

`pipe`의 stdin/stdout record는 `pts_us:u64`, `flags:u32`, `length:u32`, `data` 순서의
big-endian framing입니다. 이 framing은 M3 고정 test vector와 이후 FFmpeg adapter가
공유합니다. 64 KiB 이상 input과 일반 `pipe` output은 `memfd`/`SCM_RIGHTS`를 먼저
시도합니다. 커널에 `memfd_create`가 없거나 브로커가 확장 message를 지원하지 않으면
동일한 8 MiB 상한의 socket copy로 자동 폴백합니다. 문제 진단 시
`DAWNSHELL_CODEC_DISABLE_SHM=1`로 shared-memory 시도를 끌 수 있습니다.

이 경로는 Unix socket을 통한 대형 payload 복사를 줄이지만 MediaCodec buffer와
Debian 프로세스 사이의 완전한 zero-copy를 의미하지는 않습니다. 브로커는 받은 FD를
요청마다 닫고, 정확히 하나가 아닌 ancillary FD, 범위를 벗어난 길이와 capacity를
거부합니다.

## FFmpeg 어댑터(M5)

`dawnshell-hwdecode`는 FFprobe로 첫 번째 영상 스트림의 packet PTS와 형식을 읽고,
FFmpeg의 `h264_mp4toannexb` bitstream filter로 MP4/MKV의 H.264 packet을 Annex-B로
정규화합니다. 원본 packet PTS를 protocol record에 보존한 뒤 Android 하드웨어
decoder에 전달하며, 반환된 `YUV_420_888` 결과는 packed I420으로 저장합니다.

출력 확장자가 `.i420` 또는 `.yuv`이면 하드웨어 decode 결과를 그대로 보존합니다.
그 밖의 출력은 Debian FFmpeg와 `libx264`로 다시 encode/mux합니다. 따라서 현재
일반 파일 명령은 **하드웨어 decode + 소프트웨어 encode/mux** 경로이며, Android
MediaCodec surface와 zero-copy encode는 M6 이후 범위입니다. M5는 H.264, 짝수
16..4096 해상도, 평균 1..240 FPS만 허용하고 packet 수/크기, PTS 단조 증가와
I420 frame 크기를 fail-closed로 검사합니다.

`dawnshell-hwencode`는 FFmpeg로 첫 번째 video stream을 packed I420으로 변환한 뒤
Android 하드웨어 AVC encoder에 전달합니다. `.h264` 출력은 Annex-B 그대로이며,
그 밖의 컨테이너는 FFmpeg stream-copy로 mux합니다. 이 경로는 소프트웨어 decode와
하드웨어 encode 조합이고 audio stream은 포함하지 않습니다. 입력·출력 frame 수가
다르면 결과를 게시하지 않고 실패합니다.

## Surface zero-copy transcode(M6)

`CREATE_TRANSCODER(11)`은 hardware encoder의 `COLOR_FormatSurface` input을 만들고
그 Surface를 hardware decoder의 output으로 직접 설정합니다. decoder output은
`releaseOutputBuffer(..., true)`로 Surface에 전달되며 encoder EOS는
`signalEndOfInputStream()`으로 닫습니다. 따라서 full-size YUV frame은 Debian이나
Java heap으로 내려오지 않고 압축 packet만 protocol을 통과합니다.

`dawnshell-hwtranscode`는 H.264 또는 HEVC container를 FFmpeg로 demux한 뒤 이
Surface session에서 H.264로 변환하고 결과를 stream-copy mux합니다. 선택된 decoder와
encoder canonical name, `transport=surface_zero_copy`가 session 응답에 기록됩니다.
Surface color format을 광고하는 보수적 hardware pair가 없으면 software로 조용히
전환하지 않고 명시적으로 실패합니다. audio, 해상도 변경, 영상 filter 및 scaling은
지원하지 않습니다.

각 encode/transcode 시작 시 keyframe을 요청하며 첫 실제 출력 frame의 keyframe
flag를 검사합니다. Surface wrapper는 종료 전에 session 통계를 읽어 입력·출력·Surface
frame 수, EOS, `cpu_yuv_frames=0`, 오류 0을 확인한 뒤에만 결과 파일을 게시합니다.
`negative-test`는 잘못된 health payload와 존재하지 않는 session 요청을 의도적으로
거부시킨 뒤 같은 연결에서 broker health가 유지되는지 확인합니다.

최종 BFU 5회 회귀 시험에서 코덱까지 강제하려면 호스트에서 다음처럼 실행합니다.

```sh
BFU_REQUIRE_HARDWARE_CODEC=1 BFU_CYCLES=5 scripts/test-final-bfu.sh
```

각 cold boot의 unlock 전과 `USER_UNLOCKED` 후에 decode, encode, Surface transcode
자체 검사를 각각 실행합니다. 이 검사는 ADB가 BFU에서 연결되지 않는 ROM에서도 SSH
경로만으로 잠금 해제 전 코덱 동작을 판정합니다.
