# DawnShell FFmpeg hardware codec guide

[한국어](ffmpeg-hardware-codec.ko.md)

[Project home](../README.md) · [User manual](user-guide.md) ·
[Testing](testing.md)

Looking for `-hwaccel mediacodec` or `-c:v h264_mediacodec`? Those upstream
spellings are supported. See
[Upstream FFmpeg MediaCodec syntax compatibility](ffmpeg-mediacodec-compatibility.md).

## Scope

DawnShell does not pass a general-purpose GPU into Debian. Debian handles
containers and packet framing, while Android `MediaCodec` performs H.264/AVC
and HEVC codec work.

The app's file-backed 1080p test proves the Android hardware decoder only. The
commands below additionally exercise the Unix-socket/shared-memory streaming
bridge and must be tested separately.

## Setup

1. Enable **Hardware codec bridge at Direct Boot** in the app and save it.
2. Run **Configure Debian 13 systemd + SSH** again.
3. In Debian, verify the installed tools and broker.

```sh
command -v dawnshell-ffmpeg dawnshell-hwdecode dawnshell-hwencode dawnshell-hwtranscode
sudo dawnshell-codec health --format json
```

`broker_state` must be `listening`.

## First hardware command

This video-only command hardware-decodes H.264/HEVC through an Android Surface
and hardware-encodes AVC. `require` prevents silent fallback.

```sh
sudo env DAWNSHELL_FFMPEG_BRIDGE=require \
  dawnshell-ffmpeg -hide_banner -y \
  -i input.mp4 -map 0:v:0 -an \
  -c:v libx264 -b:v 4M output.mp4
```

The successful log reports the selected Android codec names,
`surface_zero_copy`, frame counts, and EOS.

## Direct commands

```sh
# Hardware-decode H.264/HEVC to packed I420.
sudo dawnshell-hwdecode input.mp4 output.i420

# Convert the input to I420 in FFmpeg, then hardware-encode AVC or HEVC.
sudo dawnshell-hwencode input.mp4 output.mp4 4000000 avc
sudo dawnshell-hwencode input.mp4 output.hevc 4000000 hevc

# Surface hardware decode followed by AVC hardware encode.
sudo dawnshell-hwtranscode input.mp4 output.mp4 4000000
```

`dawnshell-hwdecode` should use `.i420` or `.yuv` when testing decode alone. A
container output makes `/usr/bin/ffmpeg` software-encode the decoded frames.
`dawnshell-hwtranscode` produces video-only AVC.

## Live HLS and USB-webcam encoding

`dawnshell-live-encode` captures or decodes input with FFmpeg, incrementally
frames I420 video for the Android `MediaCodec` AVC encoder, and immediately
muxes the returned Annex-B stream. It does not buffer the complete input or
output in temporary files.

Preview the pipeline without opening hardware:

```sh
dawnshell-live-encode --print-plan \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1280x720 --fps 30 --bitrate 4000000 \
  --output recording.mp4
```

Record a USB UVC webcam to fragmented AVC MP4:

```sh
sudo dawnshell-live-encode \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1280x720 --fps 30 --bitrate 4000000 \
  --output recording.mp4
```

Publish a rolling HLS playlist:

```sh
sudo install -d -m 0755 /var/www/html/live
sudo dawnshell-live-encode \
  --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
  --size 1280x720 --fps 30 --bitrate 4000000 \
  --output-mode hls --hls-time 2 --hls-list-size 6 \
  --hls-delete-segments --output /var/www/html/live/index.m3u8
```

Add `--record /srv/video/webcam.mp4` to an HLS command to write fragmented MP4
and HLS simultaneously. A network HLS/RTSP source can be passed with
`--input URL --input-format auto`.

Input decode, pixel conversion, and scaling currently run in Debian FFmpeg;
Android hardware performs AVC encoding. Audio is not included. The encoder
uses a two-second keyframe interval, so a two-second HLS segment target is the
most predictable setting. Ctrl-C closes the pipeline and finalizes output.

A USB camera additionally requires host UVC/V4L2 support, a visible
`/dev/videoX`, devices-cgroup permission, and SELinux permission. Inspect it
with:

```sh
ls -l /dev/video* 2>/dev/null
v4l2-ctl --list-formats-ext -d /dev/video0
```

## Preview and trace the wrapper expansion

Print the route selected by `dawnshell-ffmpeg` without processing media:

```sh
/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg \
  -hide_banner -y -i input.mp4 -map 0:v:0 -an \
  -c:v libx264 -b:v 4M output.mp4
```

Expected plan:

```text
action=transcode input=input.mp4 output=output.mp4 codec=avc bitrate=4000000
```

Trace every shell command and expanded variable in the selected direct wrapper:

```sh
sudo bash -x /usr/local/bin/dawnshell-hwtranscode \
  input.mp4 output.mp4 4000000 \
  2>&1 | tee /tmp/dawnshell-hwtranscode.trace.log

sudo bash -x /usr/local/bin/dawnshell-hwdecode input.mp4 output.i420
sudo bash -x /usr/local/bin/dawnshell-hwencode input.mp4 output.mp4 4000000 avc
```

## Fully expanded raw Surface-transcode pipeline

The following is the wrapper-free equivalent of
`dawnshell-hwtranscode input.mp4 output.mp4 4000000` for H.264 MP4 input.

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

For HEVC input, replace `h264_mp4toannexb` with `hevc_mp4toannexb`, both
`-f h264` occurrences with `-f hevc`, and `transcode avc avc` with
`transcode hevc avc`.

`/usr/local/bin/dawnshell-codec` is the irreducible native bridge client.
Plain FFmpeg cannot call `MediaCodec` in the Android app process. The broker
accepts UID 0 peers only, so commands that use the bridge require `sudo` from a
regular Debian account.

## Make existing `ffmpeg` calls use the wrapper

```sh
sudo dawnshell-ffmpeg-integration enable
hash -r
command -v ffmpeg
```

The expected path is `/usr/local/bin/ffmpeg`. The wrapper directly executes
`/usr/bin/ffmpeg` for fallback, so it does not recurse. Programs that execute
the absolute `/usr/bin/ffmpeg` path bypass the wrapper.

Configuring Debian already enables this by default, so re-running it is
usually unnecessary. Undo the integration with:

```sh
sudo dawnshell-ffmpeg-integration disable
hash -r
```

## Modes

| Value | Behavior |
| --- | --- |
| `auto` | Hardware for supported commands; otherwise `/usr/bin/ffmpeg` |
| `require` | Fail unless a hardware plan can be produced |
| `off` | Always use `/usr/bin/ffmpeg` |

The automatic hardware route currently accepts one input and output, H.264 or
HEVC input, AVC (`libx264`/`h264`) output or raw `.i420`/`.yuv`, even dimensions
from 16 through 4096, 1–240 fps, and a bitrate from 1000 through 100000000.

Filters, CRF/preset options, multiple inputs or outputs, stream copy,
unsupported codecs, and audio processing fall back to plain FFmpeg or fail in
`require` mode. Specify `-an` because hardware output is video-only. To retain
audio, mux it afterward:

```sh
sudo env DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg \
  -y -i input.mp4 -map 0:v:0 -an -c:v libx264 -b:v 4M video-only.mp4

/usr/bin/ffmpeg -y -i video-only.mp4 -i input.mp4 \
  -map 0:v:0 -map 1:a? -c:v copy -c:a copy final.mp4
```

## Troubleshooting

```sh
sudo dawnshell-codec health --format json
```

Open **Hardware video acceleration → View hardware codec report** in the app.
If the file-backed test passes but FFmpeg fails, investigate the streaming
socket/shared-memory layer rather than hardware codec availability. If
`broker_state` is not `listening`, enable and save the bridge and configure
Debian again.
