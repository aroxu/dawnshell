# DawnShell FFmpeg hardware codec guide

[한국어](ffmpeg-hardware-codec.ko.md)

[Project home](../README.md) · [User manual](user-guide.md) ·
[Testing](testing.md)

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
dawnshell-codec health --format json
```

`broker_state` must be `listening`.

## First hardware command

This video-only command hardware-decodes H.264/HEVC through an Android Surface
and hardware-encodes AVC. `require` prevents silent fallback.

```sh
DAWNSHELL_FFMPEG_BRIDGE=require \
  dawnshell-ffmpeg -hide_banner -y \
  -i input.mp4 -map 0:v:0 -an \
  -c:v libx264 -b:v 4M output.mp4
```

The successful log reports the selected Android codec names,
`surface_zero_copy`, frame counts, and EOS.

## Direct commands

```sh
# Hardware-decode H.264/HEVC to packed I420.
dawnshell-hwdecode input.mp4 output.i420

# Convert the input to I420 in FFmpeg, then hardware-encode AVC or HEVC.
dawnshell-hwencode input.mp4 output.mp4 4000000 avc
dawnshell-hwencode input.mp4 output.hevc 4000000 hevc

# Surface hardware decode followed by AVC hardware encode.
dawnshell-hwtranscode input.mp4 output.mp4 4000000
```

`dawnshell-hwdecode` should use `.i420` or `.yuv` when testing decode alone. A
container output makes `/usr/bin/ffmpeg` software-encode the decoded frames.
`dawnshell-hwtranscode` produces video-only AVC.

## Make existing `ffmpeg` calls use the wrapper

```sh
sudo ln -sfn /usr/local/bin/dawnshell-ffmpeg /usr/local/bin/ffmpeg
hash -r
command -v ffmpeg
```

The expected path is `/usr/local/bin/ffmpeg`. The wrapper directly executes
`/usr/bin/ffmpeg` for fallback, so it does not recurse. Programs that execute
the absolute `/usr/bin/ffmpeg` path bypass the wrapper.

Undo the integration with:

```sh
sudo rm -f /usr/local/bin/ffmpeg
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
DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg \
  -y -i input.mp4 -map 0:v:0 -an -c:v libx264 -b:v 4M video-only.mp4

/usr/bin/ffmpeg -y -i video-only.mp4 -i input.mp4 \
  -map 0:v:0 -map 1:a? -c:v copy -c:a copy final.mp4
```

## Troubleshooting

```sh
dawnshell-codec health --format json
```

Open **Hardware video acceleration → View hardware codec report** in the app.
If the file-backed test passes but FFmpeg fails, investigate the streaming
socket/shared-memory layer rather than hardware codec availability. If
`broker_state` is not `listening`, enable and save the bridge and configure
Debian again.

