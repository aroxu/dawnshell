# gsmi - accelerator status monitor

[한국어](gpu-status-tool.ko.md)

[Documentation](README.md) · [FFmpeg hardware codec](ffmpeg-hardware-codec.md) ·
[User manual](user-guide.md)

## Summary

`gsmi` reports two different hardware blocks instead of labeling all
acceleration as GPU work:

- the Mali or Adreno **3D GPU**, from kernel sysfs;
- the dedicated **MediaCodec video accelerator**, from video-engine sysfs when
  available and from active DawnShell codec clients in `/proc`.

Configuring Debian installs it automatically.

```sh
gsmi
gsmi --loop 1
```

Example while a hardware video encode is running:

```text
2026-08-26T10:00:00Z   DawnShell accelerator status (gsmi)
+-----------------------------------------------------------------------+
| 3D GPU                 | Mali-G71 20 cores                            |
| 3D utilization         | 0%                                           |
| 3D clock               | idle                                         |
+-----------------------------------------------------------------------+
| Video accelerator      | Android MediaCodec video accelerator         |
| Codec activity         | active                                       |
| Codec clients          | 1                                            |
| Codec workloads        | encode=1 decode=0 transcode=0                |
| Codec utilization      | unavailable                                  |
+-----------------------------------------------------------------------+
Sources: kernel sysfs and DawnShell client processes in /proc.
MediaCodec uses a dedicated video engine, not the 3D GPU.
Codec utilization: unavailable because this kernel exports no VPU busy counter.
```

The 3D GPU can correctly remain at 0% and `suspended` during H.264/HEVC
processing. Android MediaCodec normally runs that work on a dedicated VPU,
MFC, Venus, or similarly named video block.

## What each value proves

| Field | Source | Meaning |
| --- | --- | --- |
| `3D utilization` | Mali/Adreno sysfs | Whole-device graphics/compute GPU load |
| `Codec activity` | Active DawnShell clients and optional video sysfs | A DawnShell encode, decode, or transcode is in progress |
| `Codec clients` | `/proc/*/cmdline` | Number of private codec clients; workers are not double-counted |
| `Codec workloads` | Client command | Active encode/decode/transcode counts |
| `Codec utilization` | Video-engine sysfs only | Actual VPU busy percentage when the kernel publishes it |

`active` is not converted into a guessed percentage. If the kernel hides its
VPU utilization counter, `gsmi` prints `unavailable` even though it can prove
that a DawnShell MediaCodec workload is active.

## Important limits

| Aspect | `nvidia-smi` | `gsmi` |
| --- | --- | --- |
| Data source | Vendor driver API | Kernel sysfs and DawnShell `/proc` clients |
| Per-process GPU usage | Supported | Usually unavailable |
| DawnShell codec jobs | Vendor-specific | Encode/decode/transcode client counts |
| VPU utilization | Vendor-specific | Only when the kernel exports a counter |
| VRAM | Dedicated allocation | Usually unified memory and not exposed |
| Power/fan | Often available | Rarely exposed / not applicable |

The 3D utilization value covers the entire Android device, including screen
rendering. Codec client counts cover DawnShell jobs only; other Android apps'
MediaCodec sessions cannot be enumerated through the Debian process namespace.

## Options

| Option | Description |
| --- | --- |
| `-l`, `--loop SECONDS` | Refresh every 1–3600 seconds |
| `-n`, `--count N` | Stop after N samples; requires `--loop` |
| `--format table` | Default table output |
| `--format csv` | CSV for logging |
| `--format json` | JSON for scripting |

```sh
gsmi --loop 2
gsmi --loop 1 --count 10 --format csv > accelerator-log.csv
gsmi --format json
```

The original GPU JSON fields remain available. Codec fields include
`codec_activity`, `codec_clients`, `codec_encode_clients`,
`codec_decode_clients`, `codec_transcode_clients`,
`codec_utilization_percent`, and `codec_sysfs_path`.

## Kernel interfaces read

| Kind | Example path or name |
| --- | --- |
| Qualcomm Adreno | `/sys/class/kgsl/kgsl-3d0` |
| ARM Mali | `/sys/class/misc/mali0/device`, `/sys/class/devfreq/*.mali` |
| Dedicated video engine | devfreq names containing `mfc`, `venus`, `vpu`, `vcodec`, `venc`, or `vdec` |
| Temperature | `/sys/class/thermal/thermal_zone*` |
| DawnShell codec clients | `/proc/[pid]/cmdline` |

Attribute names differ by kernel. `gsmi` recognizes common utilization names
such as `gpu_busy_percentage`, `utilisation`, `utilization`,
`busy_percentage`, `busy_percent`, and percentage-valued `load`. It never
treats an unrecognized value as a percentage.

## Troubleshooting

| Symptom | Cause and action |
| --- | --- |
| 3D GPU is 0% during MediaCodec | Expected: video uses the dedicated codec engine. Check `Codec activity`. |
| `Codec activity` is `idle` during a DawnShell job | Run `gsmi --loop 1` from another shell while FFmpeg is still processing. Ensure `/proc` is mounted. |
| `Codec utilization` is `unavailable` | The kernel exports no VPU busy counter. Activity and client counts remain valid. |
| 3D fields are `unavailable` | The kernel exposes no supported GPU sysfs node or `/sys` is not shared. |

```sh
gsmi --loop 1
gsmi --format json
ls -l /sys/class/devfreq/ 2>/dev/null
ls -l /sys/class/kgsl/ 2>/dev/null
```

See the [FFmpeg hardware codec guide](ffmpeg-hardware-codec.md) for supported
MediaCodec commands.
