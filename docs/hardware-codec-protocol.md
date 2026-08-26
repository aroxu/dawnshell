# DawnShell NDK hardware codec worker protocol v1

[한국어](hardware-codec-protocol.ko.md)

This document specifies the internal protocol between Debian 13
`dawnshell-codec` and the bionic `dawnshell-codec-worker`. This feature is
AVC/HEVC decode, encode, and Surface transcode through Android NDK
`AMediaCodec`; it is not GPU passthrough.

## Process and transport model

Every command creates one isolated process pair:

```text
Debian glibc program / FFmpeg wrapper
  └─ static Android ELF dawnshell-codec (parent)
       ├─ one memfd: control page + request slot + response slot
       ├─ one request eventfd
       ├─ one response eventfd
       └─ fork/exec
            └─ bionic dawnshell-codec-worker
                 └─ NDK AMediaCodec / AImageReader / ANativeWindow
```

There is no listening socket, TCP port, filesystem socket, registered Binder
service, `sendmsg`/`recvmsg`, or `SCM_RIGHTS` transfer. The parent installs its
descriptors as fixed child FDs 3, 4, and 5. The worker uses
`PR_SET_PDEATHSIG(SIGTERM)` and the client uses bounded graceful termination
followed by `SIGKILL`, so an interrupted client cannot leave an unbounded worker.
One request may be outstanding at a time. The worker is not a daemon and exits
with its command.

The mapping is approximately 16 MiB: one 4 KiB control page and two slots of
`32 bytes + 8 MiB`. Byte-buffer decode and encode copy complete frames through
these slots. Surface transcode moves only compressed packets through the slots;
full YUV frames remain on the Android Surface path.

## Android runtime inside the chroot

The client is static. The worker is a dynamic bionic ELF using
`/system/bin/linker[64]`. DawnShell exposes only these Android runtime trees in
the private Debian mount namespace:

- `/system`
- `/apex`
- `/linkerconfig`, when present

They are recursive read-only, `nosuid`, and `nodev` mounts. They remain
executable because the Android linker and APEX libraries must run. No Termux CE,
DawnShell app data, credential, or other writable Android data tree is mounted
for the codec path.

Before `exec`, the static client removes inherited `LD_PRELOAD`, `LD_AUDIT`,
`LD_DEBUG`, `LD_CONFIG_FILE`, and `LD_LIBRARY_PATH`. When Android's immutable
ICU APEX exists, it then sets `LD_LIBRARY_PATH` to only the ABI-matching
`/apex/com.android.i18n/lib[64]` directory. Direct bionic executables do not
receive an app class-loader namespace, and some Android linker configurations
otherwise resolve `/system/lib[64]/libmedia.so` without making its transitive
`libandroidicu.so` dependency visible. Pre-APEX Android keeps its normal legacy
linker search because this override is not set when the ICU library is absent.

## Transport control page

The page stores transport magic `DSCW` (`0x44534357`), version 1, mapping and
slot sizes, parent and worker PIDs, `WORKER_READY`/`WORKER_FAILED`/`SHUTDOWN`
flags, and request/response byte counts and sequence numbers. The parent
publishes a request with release stores and signals the request eventfd. The
worker publishes the matching response sequence and signals the response
eventfd. The parent validates both sequence and protocol framing. Startup is
bounded at ten seconds; ordinary RPC is bounded at 35 seconds.

## Protocol header

All integers in a slot use network byte order. Request and response headers are
32 bytes.

| Offset | Size | Value |
| --- | ---: | --- |
| 0 | 4 | magic `DSCB` (`0x44534342`) |
| 4 | 2 | protocol version `1` |
| 6 | 2 | message type; response is `type | 0x8000` |
| 8 | 4 | flags, zero in v1 |
| 12 | 8 | session ID; zero for create |
| 20 | 4 | payload length |
| 24 | 4 | nonzero request ID |
| 28 | 4 | zero in requests, signed status in responses |

Invalid magic, version, flags, request ID, length, or an 8 MiB limit violation
fails closed. One worker supports at most two sessions.

## Messages

- `HELLO(1)` reports protocol, `transport=inherited_memfd_eventfd`, worker type,
  `public_listener=false`, and `descriptor_transfer=false`.
- `CAPABILITIES(2)` reports AVC/HEVC and worker capabilities.
- `CREATE(3)` creates a byte-buffer decoder or encoder.
- `INPUT(4)` queues PTS, flags, a compressed packet, or I420 frame.
- `OUTPUT(5)` dequeues with a bounded timeout. Decoder YUV_420_888 planes are
  normalized to packed I420 using crop, row stride, and pixel stride.
- `FLUSH(6)`, `EOS(7)`, and `CLOSE(8)` control session state.
- `INPUT_SHARED_MEMORY(9)` and `OUTPUT_SHARED_MEMORY(10)` reserve obsolete
  descriptor-transfer message numbers and are explicitly rejected.
- `CREATE_TRANSCODER(11)` links decoder output Surface to encoder input Surface.
- `REQUEST_KEYFRAME(12)` requests an encoder sync frame.
- `HEALTH(13)` reports only the current private worker's PID, uptime, active
  sessions, request count, and errors. It is not cumulative across commands.
- `SESSION_STATS(14)` reports frames, bytes, EOS, errors, call latency,
  `media_transport=inherited_memfd_eventfd`, and Surface/CPU YUV frame counts.

## Hardware selection

DawnShell never silently falls back to a software codec. On current Android it
uses `AMediaCodecStore` hardware metadata when available. It then uses a
conservative legacy allowlist for Exynos (`OMX.Exynos`, `OMX.SEC`, `c2.exynos`)
and Qualcomm (`OMX.qcom`, `c2.qti`). `OMX.google`, `c2.android`, and secure
components are not hardware successes. Candidate create/configure/start failure
advances to the next hardware candidate; exhausting the list fails the command.
Name-based classification is a compatibility fallback, so a real device must
still prove codec and SELinux/media-service access.

## CLI and FFmpeg

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

`pipe` records contain big-endian `pts_us:u64`, `flags:u32`, `length:u32`, then
data. FFmpeg wrappers leave demux, mux, bitstream filters, and audio processing
to Debian FFmpeg and send only video codec work to the private NDK worker.

## BFU, AFU, and isolation

The APK provisions client and worker assets for armhf, arm64, and amd64. Debian
configuration installs them in `/usr/local/bin` and `/usr/local/libexec`. BFU
and AFU use the same on-demand path; `USER_UNLOCKED` does not stop Debian or hand
off a persistent codec process. If Android media services are unavailable in
BFU, only the codec command fails while PID 1, SSH, and networking continue.

The path does not enter the app Java process and has no app-UID-authenticated
endpoint. It supports only the root-managed execution path. The worker still
contacts Android media services, so Magisk SELinux domain and ROM policy apply.
Surface transcode avoids full YUV copies; byte-buffer decode and encode do not.

## Verification boundary

Host verification covers all three ABI builds with `-Werror`, static-client and
worker dependency inspection, absence of AF_UNIX/descriptor transfer and Java
broker/JNI code, runtime provisioning, read-only mounts, wrapper parsing, lint,
unit tests, and APK assembly. A real Android device is still required to prove
bionic worker startup in BFU/AFU, SELinux/media-service access, actual
Exynos/Qualcomm configure/queue/dequeue behavior, 1080p codec output, Surface
transcode, concurrency, cleanup, and long-run stability.
