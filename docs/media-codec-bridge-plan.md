# DawnShell hardware video codec decision record

[한국어](media-codec-bridge-plan.ko.md) · [Documentation](README.md) · [Worker protocol](hardware-codec-protocol.md) · [FFmpeg guide](ffmpeg-hardware-codec.md)

This is a decision record for the current implementation, not an unfinished
proposal. The [worker protocol](hardware-codec-protocol.md) is authoritative for
the wire format, and the [FFmpeg guide](ffmpeg-hardware-codec.md) is authoritative
for user commands.

## Goals and non-goals

DawnShell does not pass OpenGL, Vulkan, or a general-purpose GPU into Debian.
Debian FFmpeg performs demuxing, packet framing, optional software preprocessing,
and muxing. An Android NDK `AMediaCodec` worker performs AVC/HEVC decode and
encode.

Explicit non-goals are:

- general GPU compute or VirGL;
- loading Android bionic libraries into a Debian glibc process;
- a public TCP/Unix listener or registered Binder service;
- a persistent codec daemon;
- silent software-codec fallback after hardware was requested.

## Chosen process model

```text
Debian FFmpeg wrapper
  → static dawnshell-codec client
  → create one memfd + two eventfds
  → fork/exec dawnshell-codec-worker
  → inherited-FD ready handshake
  → bionic NDK AMediaCodec
  → bounded response records
  → reap the worker
```

The worker is installed at `/usr/local/libexec/dawnshell-codec-worker`. Client
and worker share only fixed descriptors 3, 4, and 5. There is no
`sendmsg`/`recvmsg`, `SCM_RIGHTS`, filesystem socket, or abstract socket. Request
and response payloads are limited to 8 MiB, and both sides validate protocol
version, sequence, length, and status.

A parent-death signal terminates the worker when the client disappears. Normal,
error, and signal paths all reap the worker. A different worker PID for each
command is expected.

## Android runtime view

The dynamic bionic worker sees only the Android runtime trees needed by the
linker, recursively read-only inside Debian's private mount namespace:

- `/system`
- `/apex`
- `/linkerconfig`, when present

No normal app CE data is mounted. Runtime mounts disappear with the private
namespace when Debian stops.

## Codec paths

- Decode: NDK decoder → `AImageReader` YUV_420_888 → normalized I420
- Encode: I420 byte buffer → NDK encoder → Annex-B AVC/HEVC
- Transcode: decoder output Surface → encoder input Surface

Surface transcode avoids a round trip of complete YUV frames through Debian.
Standalone decode and encode use bounded shared slots. Hardware selection uses
platform metadata and conservative Exynos/Qualcomm component names. Secure,
`OMX.google.*`, and `c2.android.*` components do not count as hardware success.

## BFU and AFU behavior

BFU and AFU use the same on-demand worker model. No broker starts at boot.
`USER_UNLOCKED` does not stop Debian, and there is no codec daemon to hand off.

The validation sequence is:

1. Run `dawnshell-codec health` and the self-test through BFU SSH.
2. Unlock Android without stopping Debian.
3. Verify the same PID 1 and SSH session remain.
4. Run health and self-test again, creating a new private AFU worker.

If Android media services are not ready during BFU, only the codec command may
fail. Debian PID 1, SSH, and Direct Boot operation must remain healthy.

## Security boundary

- There is no listener for an external peer to connect to.
- Only the direct child inheriting the descriptors can use the transport.
- Payload, session count, resolution, frame rate, bitrate, and timeout are bounded.
- No silent software fallback is available.
- The worker receives no normal app CE data or credentials.
- The managed native/chroot path is root-only.

## Static completion criteria

- Build armv7, arm64, and x86_64 client/worker pairs.
- Keep the client static and the worker's bionic dependencies constrained.
- Package each ABI pair in the APK.
- Keep Java socket broker/JNI prototype code out of the package.
- Pass shell syntax/lint, JVM unit tests, and APK assembly.
- Keep UI and documentation aligned with the private-worker model.

## Physical-device completion criteria

- Prove `worker_state=ready` and hardware codec creation during BFU.
- Validate 1080p H.264/HEVC files and Surface transcode.
- Repeat after unlock while preserving Debian PID 1.
- Verify malformed input, concurrent workers, and interrupted-client cleanup.
- Complete five cold boots and long-run thermal/CPU/RSS collection.

These physical results remain separate from host-build validation. A feature is
not marked fully validated on a platform until the corresponding device test has
passed.
