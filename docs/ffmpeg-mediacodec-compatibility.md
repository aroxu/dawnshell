# Upstream FFmpeg MediaCodec syntax compatibility

[한국어](ffmpeg-mediacodec-compatibility.ko.md)

[Documentation](README.md) · [FFmpeg hardware codec](ffmpeg-hardware-codec.md) ·
[User manual](user-guide.md) · [Testing](testing.md)

## What this document answers

Why the stock `ffmpeg` inside Debian cannot use `-hwaccel mediacodec`
directly, and how DawnShell supports that syntax anyway.

## 1. Why stock Debian FFmpeg cannot do it

FFmpeg does support MediaCodec, but only in builds targeting the Android
platform. Every one of the following is required:

| Requirement | Detail | Debian rootfs reality |
| --- | --- | --- |
| Build target | `--target-os=android` | Debian packages target `linux` |
| C library | bionic | glibc |
| Build flags | `--enable-mediacodec --enable-jni` | Not enabled |
| Link target | Android bionic `libmediandk.so` | Incompatible with a glibc process |
| Runtime | Android linker, `/system`, and APEX view | Not part of a normal Debian rootfs |
| Codec API | NDK or JNI caller | Debian package has neither path |

The blocker is not a missing configure flag. Debian FFmpeg is a glibc Linux
process, while NDK MediaCodec libraries are bionic Android libraries. DawnShell
therefore keeps stock FFmpeg for parsing/muxing and runs only codec work in a
small bionic worker.

Verify it locally:

```sh
/usr/bin/ffmpeg -hide_banner -hwaccels
/usr/bin/ffmpeg -hide_banner -encoders | grep -i mediacodec || true
```

Neither command should list `mediacodec`.

### Why not ship an Android FFmpeg build instead

It is theoretically possible, but it requires all of the following:

- A bionic-based Android FFmpeg cross build
- Exposing `/system/lib64` and the Android linker inside the chroot
- Preserving Android linker and SELinux behavior for a very large executable
- Maintaining Android-specific FFmpeg builds for every supported ABI

That makes the trusted Android-side surface much larger. DawnShell instead
ships a narrowly scoped NDK worker and keeps Debian's packaged FFmpeg unchanged.

## 2. DawnShell's approach: upstream syntax, bridged execution

DawnShell accepts the same command-line **syntax** as upstream FFmpeg and
forwards only the codec work to an on-demand bionic NDK worker.

```text
User command (-hwaccel mediacodec / -c:v h264_mediacodec)
        ↓
dawnshell-ffmpeg            command interpretation
        ↓
plan-ffmpeg                 route selection
        ↓
dawnshell-hwdecode / hwencode / hwtranscode
        ↓
dawnshell-codec             static client: fork/exec + inherited FDs
        ↓
dawnshell-codec-worker      bionic NDK AMediaCodec process
        ↓
Android MediaCodec service
```

Two points matter:

- The command syntax and the produced files are compatible with upstream.
- `/usr/bin/ffmpeg` never opens MediaCodec. The private bionic worker does.
- The client and worker use one inherited `memfd` plus two inherited `eventfd`
  objects. No socket, descriptor passing, registered service, or persistent
  codec daemon is involved.

### The wrapper is wired in by default

Configuring Debian installs `/usr/local/bin/ffmpeg` as a symlink to the
wrapper. Because `/usr/local/bin` precedes `/usr/bin` on the default PATH,
existing programs that call `ffmpeg` by name reach the hardware route without
any change. Debian's packaged `/usr/bin/ffmpeg` file is never modified.

```sh
command -v ffmpeg
readlink /usr/local/bin/ffmpeg
dawnshell-ffmpeg-integration status
```

Turn the integration off or back on with:

```sh
sudo dawnshell-ffmpeg-integration disable
hash -r

sudo dawnshell-ffmpeg-integration enable
hash -r
```

`disable` removes only DawnShell's own symlink and refuses to touch anything
else placed at that path. Programs that execute the absolute
`/usr/bin/ffmpeg` path always use stock FFmpeg regardless of this setting.

## 3. Supported upstream syntax

| Upstream FFmpeg syntax | DawnShell behavior | Execution path |
| --- | --- | --- |
| `-hwaccel mediacodec` + raw output | Hardware decode | `dawnshell-hwdecode` |
| `-c:v h264_mediacodec` | Hardware AVC encode | `dawnshell-hwencode` |
| `-c:v hevc_mediacodec` | Hardware HEVC encode | `dawnshell-hwencode` |
| `-c:a copy` with MediaCodec encode | Copy the first input audio stream into the output | Hardware encode + final stream-copy mux |
| `-hwaccel mediacodec` + `-c:v h264_mediacodec` | Surface zero-copy transcode | `dawnshell-hwtranscode` |
| `-hwaccel mediacodec` + `-c:v libx264` | Surface zero-copy transcode | `dawnshell-hwtranscode` |
| `-c:v h264_mediacodec` before `-i` | Hardware **decoder** selection | Depends on output codec |
| `-hwaccel auto`, `-hwaccel none` | Accepted and ignored | Depends on output codec |

FFmpeg's option-position rule is honored: a `-c:v` before `-i` selects a
decoder, and a `-c:v` after `-i` selects an encoder.

### Examples

Hardware AVC encode:

```sh
sudo ffmpeg -hide_banner -y -i input.mp4 -map 0:v:0 -an \
  -c:v h264_mediacodec -b:v 4M output.mp4
```

Hardware AVC encode while preserving audio:

```sh
sudo ffmpeg -y -i input.mp4 -c:a copy \
  -c:v h264_mediacodec output.mp4
```

Surface zero-copy transcode:

```sh
sudo ffmpeg -hide_banner -y -hwaccel mediacodec -i input.mp4 \
  -map 0:v:0 -an -c:v h264_mediacodec -b:v 6M output.mp4
```

Hardware decode only:

```sh
sudo ffmpeg -hide_banner -y -hwaccel mediacodec -i input.mp4 output.yuv
```

## 4. The important safety rule

If a command names `mediacodec` explicitly, DawnShell treats hardware as a
requirement. When no hardware plan is possible, the command exits with an
error instead of quietly using `libx264`.

```sh
sudo ffmpeg -i input.mp4 -vf scale=1280:720 -c:v h264_mediacodec out.mp4
# dawnshell-ffmpeg: hardware bridge required but unavailable: ...
# exit 3
```

This protects performance and battery measurements. A silent software
substitution behind an explicit hardware request is the most misleading
failure mode.

Request software explicitly when you want it:

```sh
DAWNSHELL_FFMPEG_BRIDGE=off sudo -E ffmpeg -i input.mp4 \
  -vf scale=1280:720 -c:v libx264 out.mp4
```

## 5. Modes

| Value | Behavior | With explicit `mediacodec` |
| --- | --- | --- |
| `auto` (default) | Hardware when supported, otherwise software | Escalated to require |
| `require` | Fail when hardware is impossible | Same |
| `off` | Always `/usr/bin/ffmpeg` | Software wins; the switch is explicit |

## 6. Automatic hardware scope

Supported:

- One input file and one output file
- The first video stream
- H.264 or HEVC input
- AVC or HEVC output, or raw `.i420`/`.yuv` output
- Even dimensions from 16 through 4096
- 1–240 fps
- Bitrate from 1000 through 100000000 bit/s
- `-c:a copy` for the first optional input audio stream on ByteBuffer hardware
  encode
- `-hide_banner`, `-y`, `-n`, `-an`, `-nostdin`, `-loglevel`, `-v`,
  `-threads`, `-stats_period`, `-pix_fmt`, `-f`, `-r`, limited `-map`,
  `-hwaccel_output_format`, `-hwaccel_device`, `-hwaccel_flags`

Not supported (software fallback or error):

- Filters and scaling such as `-vf` or `-filter`
- x264/x265-specific options such as `-crf` and `-preset`
- Multiple inputs or outputs
- `-c:v copy`
- Unsupported codecs such as VP9 and AV1
- Audio encoding and filtering; arbitrary audio mapping
- Other accelerators such as `-hwaccel cuda`

The ByteBuffer hardware encode route can preserve the first optional audio
stream with `-c:a copy`. Surface zero-copy transcode remains video-only.

## 7. Differences from upstream FFmpeg

| Aspect | Upstream Android FFmpeg | DawnShell |
| --- | --- | --- |
| Codec caller | The FFmpeg process | Private bionic NDK worker |
| Privileges | App/process permissions | Root-managed native/chroot path |
| Simultaneous audio | Supported | First optional audio stream-copy on ByteBuffer encode |
| Filters plus hardware | Partially supported | Not supported |
| `-hwaccel_output_format` | Meaningful | Accepted and ignored |
| Failure behavior | Configuration dependent | Error when hardware was named |
| Latency | In-process | Child process through inherited shared slots |

`sudo` is required because DawnShell installs and exposes the managed native
runtime only through its root-owned chroot path. There is no peer-credential
listener to authenticate.

## 8. Preflight and troubleshooting

Print the selected route without touching media:

```sh
/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg \
  -hwaccel mediacodec -i input.mp4 -map 0:v:0 -an \
  -c:v h264_mediacodec -b:v 6M output.mp4
```

Example output:

```text
action=transcode input=input.mp4 output=output.mp4 codec=avc bitrate=6000000 explicit=mediacodec
```

| Field | Meaning |
| --- | --- |
| `action=decode` | Hardware decode only |
| `action=encode` | Hardware encode only |
| `action=transcode` | Surface zero-copy decode plus encode |
| `action=passthrough` | Outside the automatic hardware scope |
| `explicit=mediacodec` | The caller named hardware |
| `reason=...` | Fallback cause |

Inspect a freshly started private worker:

```sh
sudo dawnshell-codec health --format json
systemctl status dawnshell-codec-long-run.service --no-pager
journalctl -u dawnshell-codec-long-run.service -n 100 --no-pager
```

| Symptom | Cause and action |
| --- | --- |
| `hardware bridge required but unavailable` | The command is outside automatic scope; check `reason` from `plan-ffmpeg`. |
| `Surface transcode only produces H.264` | Drop `-hwaccel mediacodec` for HEVC output. |
| `worker_state` is not `ready` | Enable and save the feature, configure Debian again, and verify the worker plus `/system`/`/apex` mounts. |
| `worker startup timed out` | The bionic worker exited before its inherited-FD ready handshake; inspect stderr and runtime mounts. |
| `Connection refused` | An obsolete socket-based client is still installed; configure Debian again from the current APK. |
| File test passes but the command fails | Investigate client/worker launch and inherited shared transport, not codec availability. |

In the app, open **Hardware video acceleration → View hardware codec report**.
