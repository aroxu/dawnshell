# DawnShell FFmpeg 하드웨어 코덱 사용법

[English](ffmpeg-hardware-codec.md)

[프로젝트 홈](../README.ko.md) · [사용자 매뉴얼](user-guide.ko.md) ·
[테스트 안내](testing.ko.md)

## 기능 범위

DawnShell은 Debian의 일반 GPU를 패스스루하지 않습니다. Debian에서 컨테이너와
패킷을 정리하고, Android 앱 프로세스의 `MediaCodec`이 H.264/AVC 및 HEVC
디코드와 인코드를 수행합니다.

앱의 **파일 기반 하드웨어 AVC 디코드 자체 검사**는 Android 하드웨어 디코더가
작동하는지만 확인합니다. 아래 FFmpeg 명령은 Unix socket/공유 메모리를 포함한
스트리밍 브리지까지 사용하므로 별도로 확인해야 합니다.

## 최초 준비

1. 앱에서 **다이렉트 부트에서 하드웨어 코덱 브리지 활성화**를 켭니다.
2. **저장하고 하드웨어 코덱 검사**를 누릅니다.
3. **Debian 13 systemd + SSH 구성**을 다시 실행합니다.
4. Debian에서 다음을 확인합니다.

```sh
command -v dawnshell-ffmpeg dawnshell-hwdecode dawnshell-hwencode dawnshell-hwtranscode
sudo dawnshell-codec health --format json
```

`health` 결과의 `broker_state`가 `listening`이어야 합니다. 도구가 없다면 앱에서
Debian 구성을 다시 실행하세요.

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

여기서 `/usr/local/bin/dawnshell-codec`는 제거할 수 없는 최소 브리지입니다. 일반
FFmpeg만으로 Android 앱 프로세스의 `MediaCodec`을 호출할 수 없으며, 이 네이티브
클라이언트가 인증된 Android 브로커에 프레임과 제어 요청을 전달합니다. 브로커는
보안을 위해 UID 0 연결만 허용하므로 일반 Debian 계정에서는 `sudo`가 필요합니다.

## 기존 `ffmpeg` 호출에 자동 적용

`/usr/local/bin`이 `/usr/bin`보다 앞에 있는 기본 Debian PATH에서 다음 symlink를
만들면, `ffmpeg`를 이름으로 실행하는 프로그램이 DawnShell 래퍼를 먼저 찾습니다.

```sh
sudo ln -sfn /usr/local/bin/dawnshell-ffmpeg /usr/local/bin/ffmpeg
hash -r
command -v ffmpeg
```

예상 경로는 `/usr/local/bin/ffmpeg`입니다. 래퍼 자체는 폴백할 때 항상
`/usr/bin/ffmpeg`를 직접 실행하므로 재귀 호출하지 않습니다. 프로그램이
`/usr/bin/ffmpeg`를 절대 경로로 실행하면 이 연동을 우회합니다.

되돌리려면 다음을 실행합니다.

```sh
sudo rm -f /usr/local/bin/ffmpeg
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

- 파일 기반 검사는 성공하지만 FFmpeg가 실패함: 코덱 자체가 아니라 socket/공유
  메모리 스트리밍 계층을 확인합니다.
- `action=passthrough`: 해당 명령은 자동 하드웨어 범위 밖입니다. `require`로 이유를
  명확한 오류로 바꿀 수 있습니다.
- `broker_state`가 `listening`이 아님: 앱에서 브리지를 켜고 저장한 뒤 Debian 구성을
  다시 실행합니다.
- BFU에서만 실패함: Android 미디어 서비스가 늦게 준비되는 ROM일 수 있습니다.
  앱 로그의 locked-boot 재시도 결과를 확인합니다.
