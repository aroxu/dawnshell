# DawnShell FFmpeg 하드웨어 코덱 사용법

[English](ffmpeg-hardware-codec.md)

[프로젝트 홈](../README.ko.md) · [사용자 매뉴얼](user-guide.ko.md) ·
[테스트 안내](testing.ko.md)

`-hwaccel mediacodec`이나 `-c:v h264_mediacodec` 같은 순정 FFmpeg 문법도
지원합니다. 자세한 내용은
[순정 FFmpeg 문법 호환성 (MediaCodec)](ffmpeg-mediacodec-compatibility.ko.md)을
참고하세요.

## 기능 범위

DawnShell은 Debian의 일반 GPU를 패스스루하지 않습니다. Debian에서 컨테이너와
패킷을 정리하고, 명령별 bionic NDK worker의 `MediaCodec`이 H.264/AVC 및 HEVC
디코드와 인코드를 수행합니다.

앱의 **파일 기반 하드웨어 AVC 디코드 자체 검사**는 Android 하드웨어 디코더가
작동하는지만 확인합니다. 아래 FFmpeg 명령은 Debian 정적 client, 상속 공유
전송, 명령별 private NDK worker와 FFmpeg adapter를 별도로 확인합니다.

## 최초 준비

1. 앱에서 **다이렉트 부트에서 하드웨어 코덱 브리지 활성화**를 켭니다.
2. **저장하고 하드웨어 코덱 검사**를 누릅니다.
3. **Debian 13 systemd + SSH 구성**을 다시 실행합니다.
4. Debian에서 다음을 확인합니다.

```sh
command -v dawnshell-ffmpeg dawnshell-hwdecode dawnshell-hwencode dawnshell-hwtranscode
sudo dawnshell-codec health --format json
```

`health` JSON에는 다음 값이 모두 있어야 합니다.

```text
worker_state=ready
transport=inherited_memfd_eventfd
public_listener=false
software_fallback=false
```

`health`는 새 worker를 시작해 상태를 읽고 회수합니다. 명령마다 PID가 달라지는
것이 정상이며 유지해야 할 daemon은 없습니다. 도구가 없다면 앱에서 Debian 구성을
다시 실행하세요.

## 가장 먼저 실행할 명령

다음 명령은 H.264 또는 HEVC 입력을 Android Surface 경로에서 디코드하고 AVC로
다시 인코드합니다. `require`를 사용했으므로 일반 FFmpeg로 조용히 폴백하지
않습니다.

```sh
sudo env DAWNSHELL_FFMPEG_BRIDGE=require \
  dawnshell-ffmpeg -hide_banner -y \
  -i input.mp4 -map 0:v:0 -an \
  -c:v libx264 -b:v 4M output.mp4
```

성공 로그에는 선택된 Android 코덱 이름과 `surface_zero_copy`, 입력·출력 프레임,
EOS 통계가 표시됩니다. `OMX.google.*` 또는 `c2.android.*` 같은 소프트웨어
코덱은 하드웨어 성공으로 인정하지 않습니다.

## 세 가지 직접 명령

### 하드웨어 디코드

H.264/HEVC를 packed I420 파일로 디코드합니다.

```sh
sudo dawnshell-hwdecode input.mp4 output.i420
```

출력 크기는 `width × height × 3 / 2 × frame_count`입니다. `.mp4` 같은 컨테이너를
출력으로 지정하면 디코드 뒤 `/usr/bin/ffmpeg`의 `libx264`로 다시 인코드하므로,
순수 디코드 검사에는 `.i420` 또는 `.yuv`를 사용하세요.

### 하드웨어 인코드

입력 영상은 일반 FFmpeg가 I420로 변환하고 Android 하드웨어 인코더가 AVC 또는
HEVC로 인코드합니다.

```sh
sudo dawnshell-hwencode input.mp4 output.mp4 4000000 avc
sudo dawnshell-hwencode input.mp4 output.hevc 4000000 hevc
```

인자는 `INPUT OUTPUT [BITRATE] [avc|hevc]` 순서입니다. bitrate 범위는
1000~100000000 bit/s입니다.

### Surface 하드웨어 트랜스코드

H.264/HEVC 입력을 Surface로 하드웨어 디코드하고, CPU로 전체 YUV 프레임을
돌려보내지 않은 채 AVC 하드웨어 인코더에 연결합니다.

```sh
sudo dawnshell-hwtranscode input.mp4 output.mp4 4000000
```

현재 출력 코덱은 AVC입니다. 오디오 stream은 포함하지 않습니다.

## 실시간 HLS·USB 웹캠 인코딩

`dawnshell-live-encode`는 입력을 FFmpeg로 실시간 캡처·디코드하고 I420 frame을
Android `MediaCodec` AVC 인코더로 보낸 다음, 결과 Annex-B stream을 파일이나
HLS로 즉시 mux합니다. 전체 입력과 출력을 임시 파일에 모으지 않습니다.

Debian 구성을 다시 실행한 뒤 설치 여부와 실제 실행 계획을 확인합니다.

```sh
command -v dawnshell-live-encode
dawnshell-live-encode --print-plan \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1280x720 --fps 30 --bitrate 4000000 \
  --output recording.mp4
```

USB UVC 웹캠을 실시간 AVC MP4로 저장합니다.

```sh
sudo dawnshell-live-encode \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1280x720 --fps 30 --bitrate 4000000 \
  --output recording.mp4
```

웹캠을 HLS로 송출합니다. 웹 서버가 `/var/www/html/live`를 제공한다고
가정합니다.

```sh
sudo install -d -m 0755 /var/www/html/live
sudo dawnshell-live-encode \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1280x720 --fps 30 --bitrate 4000000 \
  --output-mode hls --hls-time 2 --hls-list-size 6 \
  --hls-delete-segments --output /var/www/html/live/index.m3u8
```

HLS와 fragmented MP4 녹화를 동시에 생성할 수도 있습니다.

```sh
sudo dawnshell-live-encode \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1920x1080 --fps 30 --bitrate 8000000 \
  --output-mode hls --output /var/www/html/live/index.m3u8 \
  --record /srv/video/webcam.mp4
```

HLS·RTSP·일반 파일 입력을 하드웨어 AVC로 다시 인코드할 때는 입력 형식을
`auto`로 둡니다.

```sh
sudo dawnshell-live-encode \
  --input 'https://example.invalid/live/index.m3u8' \
  --input-format auto --size 1280x720 --fps 30 --bitrate 4000000 \
  --output-mode hls --output /var/www/html/restream/index.m3u8
```

이 실시간 경로에서 입력 디코드·색상 변환·크기 변환은 Debian FFmpeg가
수행하고 **AVC 인코드만 Android 하드웨어**가 수행합니다. 현재 오디오는
포함하지 않습니다. 인코더의 keyframe 간격은 2초이므로 HLS segment 목표도
2초가 가장 예측 가능합니다. `Ctrl-C`를 누르면 파이프라인을 종료하고 MP4/HLS
출력을 정상 마무리합니다.

USB 웹캠은 호스트 커널의 UVC/V4L2 지원, Debian에 노출된 `/dev/videoX`, devices
cgroup 허용, SELinux 접근 허용이 모두 필요합니다. 먼저 다음으로 지원 형식을
확인하세요.

```sh
ls -l /dev/video* 2>/dev/null
v4l2-ctl --list-formats-ext -d /dev/video0
```

## 래퍼가 선택할 명령 미리 보기

다음 명령은 미디어를 실행하지 않고 `dawnshell-ffmpeg`가 선택할 경로만 출력합니다.

```sh
/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg \
  -hide_banner -y -i input.mp4 -map 0:v:0 -an \
  -c:v libx264 -b:v 4M output.mp4
```

이 예제의 결과는 다음과 같습니다.

```text
action=transcode input=input.mp4 output=output.mp4 codec=avc bitrate=4000000
```

실제 실행 중 래퍼가 호출하는 셸 명령과 변수 값을 모두 보려면 선택된 직접 래퍼를
`bash -x`로 실행합니다.

```sh
sudo bash -x /usr/local/bin/dawnshell-hwtranscode \
  input.mp4 output.mp4 4000000 \
  2>&1 | tee /tmp/dawnshell-hwtranscode.trace.log
```

디코드와 인코드도 같은 방식으로 추적할 수 있습니다.

```sh
sudo bash -x /usr/local/bin/dawnshell-hwdecode input.mp4 output.i420
sudo bash -x /usr/local/bin/dawnshell-hwencode input.mp4 output.mp4 4000000 avc
```

## Surface 트랜스코드의 완전히 펼친 원시 명령

아래는 H.264 MP4 입력을 AVC MP4로 변환하는
`dawnshell-hwtranscode input.mp4 output.mp4 4000000`의 핵심을 래퍼 없이 펼친
형태입니다. 일반 사용자라면 먼저 `sudo -i`로 root shell에 들어갑니다.

```sh
sudo -i

input=/absolute/path/input.mp4
output=/absolute/path/output.mp4
bit_rate=4000000
temporary="$(mktemp -d /run/dawnshell-raw-transcode.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

stream_info="$temporary/stream.txt"
input_packets="$temporary/input-packets.json"
annex_b="$temporary/input.h264"
raw_packets="$temporary/raw-packets.json"
framed_input="$temporary/framed-input.bin"
framed_output="$temporary/framed-output.bin"
encoded="$temporary/output.h264"
client_log="$temporary/client.log"

/usr/bin/ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,avg_frame_rate \
  -of default=noprint_wrappers=1 "$input" > "$stream_info"
width="$(sed -n 's/^width=//p' "$stream_info" | head -n 1)"
height="$(sed -n 's/^height=//p' "$stream_info" | head -n 1)"
frame_rate="$(sed -n 's/^avg_frame_rate=//p' "$stream_info" | head -n 1)"
integer_rate="$(printf '%s\n' "$frame_rate" | mawk -F/ \
  'NF == 2 { printf "%d\\n", int(($1 / $2) + 0.5) }')"

/usr/bin/ffprobe -v error -select_streams v:0 -show_packets \
  -show_entries packet=pts_time,dts_time -of json \
  "$input" > "$input_packets"

/usr/bin/ffmpeg -hide_banner -loglevel error -y -i "$input" \
  -map 0:v:0 -an -c:v copy -bsf:v h264_mp4toannexb \
  -f h264 "$annex_b"

/usr/bin/ffprobe -v error -f h264 -show_packets \
  -show_entries packet=pos,size -of json \
  "$annex_b" > "$raw_packets"

/usr/local/libexec/dawnshell-codec-ffmpeg.py pack \
  "$input_packets" "$raw_packets" "$annex_b" "$frame_rate" "$framed_input"

/usr/local/bin/dawnshell-codec transcode \
  avc avc "$width" "$height" "$integer_rate" "$bit_rate" \
  < "$framed_input" > "$framed_output" 2> "$client_log"

cat "$client_log" >&2
frames="$(/usr/local/libexec/dawnshell-codec-ffmpeg.py unpack-annexb \
  "$framed_output" "$encoded" --require-keyframe)"
/usr/local/libexec/dawnshell-codec-ffmpeg.py validate-stats \
  "$client_log" "$frames"

/usr/bin/ffmpeg -hide_banner -loglevel error -y \
  -r "$frame_rate" -f h264 -i "$encoded" \
  -map 0:v:0 -an -c:v copy "$output"
```

HEVC 입력은 `h264_mp4toannexb`를 `hevc_mp4toannexb`로, 두 `-f h264`를
`-f hevc`로, `dawnshell-codec transcode avc avc`를
`dawnshell-codec transcode hevc avc`로 바꿉니다.

여기서 `/usr/local/bin/dawnshell-codec`는 제거할 수 없는 정적 Android ELF
client입니다. 이 client가 `memfd` 하나와 `eventfd` 두 개를 만들고 fork한 다음,
그 descriptor만 상속한 `/usr/local/libexec/dawnshell-codec-worker`를 실행합니다.
bionic worker는 NDK `AMediaCodec`을 호출하고 상한이 있는 record를 반환한 뒤
부모와 함께 종료합니다. listening endpoint와 descriptor 전달은 없습니다. 일반
glibc FFmpeg만으로 `MediaCodec`을 직접 호출할 수 없습니다. 관리되는 native/chroot
실행 경로가 root 전용이므로 일반 Debian 계정에서는 `sudo`가 필요합니다.

## 기존 `ffmpeg` 호출에 자동 적용

`/usr/local/bin`이 `/usr/bin`보다 앞에 있는 기본 Debian PATH에서 다음 symlink를
만들면, `ffmpeg`를 이름으로 실행하는 프로그램이 DawnShell 래퍼를 먼저 찾습니다.

```sh
sudo dawnshell-ffmpeg-integration enable
hash -r
command -v ffmpeg
```

예상 경로는 `/usr/local/bin/ffmpeg`입니다. 래퍼 자체는 폴백할 때 항상
`/usr/bin/ffmpeg`를 직접 실행하므로 재귀 호출하지 않습니다. 프로그램이
`/usr/bin/ffmpeg`를 절대 경로로 실행하면 이 연동을 우회합니다.

이 연결은 Debian 구성 시 이미 기본으로 적용되므로 보통 다시 실행할 필요가
없습니다. 되돌리려면 다음을 실행합니다.

```sh
sudo dawnshell-ffmpeg-integration disable
hash -r
```

## 자동 래퍼 모드

| 값 | 동작 |
| --- | --- |
| `auto` | 지원되는 명령은 하드웨어, 그 외에는 `/usr/bin/ffmpeg` |
| `require` | 하드웨어 계획을 만들 수 없으면 오류로 종료 |
| `off` | 항상 `/usr/bin/ffmpeg` |

```sh
sudo env DAWNSHELL_FFMPEG_BRIDGE=auto dawnshell-ffmpeg ...
sudo env DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg ...
DAWNSHELL_FFMPEG_BRIDGE=off dawnshell-ffmpeg ...
```

성능이나 호환성을 검사할 때는 반드시 `require`를 사용하세요. `auto`에서는 성공한
일반 FFmpeg 실행을 하드웨어 성공으로 오인할 수 있습니다.

## 자동 하드웨어 경로가 처리하는 명령

- 입력 파일 하나와 출력 파일 하나
- 첫 번째 영상 stream
- H.264 또는 HEVC 입력
- `libx264`/`h264` AVC 출력 또는 `.i420`/`.yuv` 출력
- 짝수 해상도 16~4096
- 1~240 fps
- bitrate 1000~100000000 bit/s
- `-hide_banner`, `-y`, `-n`, `-an`, `-nostdin`, `-loglevel`, `-v`,
  `-threads`, `-stats_period`, `-pix_fmt`, `-f`, `-r`, 제한된 `-map`

다음 요청은 일반 FFmpeg로 폴백하거나 `require` 모드에서 실패합니다.

- `-vf`, `-filter` 등 필터와 크기 변환
- `-crf`, `-preset` 같은 x264/x265 전용 설정
- 복수 입력 또는 복수 출력
- 영상 이외 stream mapping
- `-c:v copy`
- VP9, AV1 등 지원하지 않는 코덱
- 오디오 인코드·필터·mapping 옵션

하드웨어 경로는 영상 전용이므로 예제처럼 `-an`을 명시하세요. 원본 오디오를
유지하려면 영상 작업 후 일반 FFmpeg로 다시 mux합니다.

```sh
sudo env DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg \
  -y -i input.mp4 -map 0:v:0 -an -c:v libx264 -b:v 4M video-only.mp4

/usr/bin/ffmpeg -y -i video-only.mp4 -i input.mp4 \
  -map 0:v:0 -map 1:a? -c:v copy -c:a copy final.mp4
```

## 문제 해결

```sh
sudo dawnshell-codec health --format json
systemctl status dawnshell-codec-long-run.service --no-pager
journalctl -u dawnshell-codec-long-run.service -n 100 --no-pager
```

앱에서는 **하드웨어 영상 가속 → 하드웨어 코덱 보고서 보기**를 엽니다.

- 파일 기반 검사는 성공하지만 FFmpeg가 실패함: 코덱 자체가 아니라
  client/private-worker 경로를 확인합니다.
- `action=passthrough`: 해당 명령은 자동 하드웨어 범위 밖입니다. `require`로 이유를
  명확한 오류로 바꿀 수 있습니다.
- `worker_state=ready`가 없음: 앱에서 기능을 켜고 저장한 뒤 Debian 구성을 다시
  실행하고 아래 파일과 Android runtime mount를 확인합니다.
- BFU에서만 실패함: Android 미디어 서비스가 늦게 준비되는 ROM일 수 있습니다.
  앱 로그의 locked-boot 재시도 결과를 확인합니다.

```sh
sudo test -x /usr/local/bin/dawnshell-codec
sudo test -x /usr/local/libexec/dawnshell-codec-worker
findmnt /system /apex /linkerconfig 2>/dev/null || true
sudo dawnshell-codec health --format json
```

`worker startup timed out`은 대개 bionic dynamic linker 경로가 보이지 않거나 ready
handshake 전에 worker가 종료된 경우입니다. `hardware codec ... unavailable`은 해당
Android 플랫폼에서 허용된 하드웨어 component를 찾지 못한 경우입니다.
`Connection refused`는 폐기된 socket 기반 빌드의 오류이며 현재 구조에서는 나오면
안 됩니다.
