# gsmi - GPU status monitor

[한국어](gpu-status-tool.ko.md)

[Project home](../README.md) · [FFmpeg hardware codec](ffmpeg-hardware-codec.md) ·
[User manual](user-guide.md)

## Summary

`gsmi` reports GPU utilization, clock, governor, and temperature in a layout
similar to `nvidia-smi`. Configuring Debian installs it automatically.

```sh
gsmi
```

Example output:

```text
2026-08-25T12:04:22Z   DawnShell GPU status (gsmi)
+-----------------------------------------------------------------------+
| GPU                    | Adreno540                                    |
| Utilization            | 37%                                          |
| Clock                  | 710MHz                                       |
| Max clock              | 710MHz                                       |
| Governor               | msm-adreno-tz                                |
| Power state            | active                                       |
| Temperature            | 41.2C                                        |
+-----------------------------------------------------------------------+
```

## Important limits

| Aspect | nvidia-smi | gsmi |
| --- | --- | --- |
| Data source | Vendor driver API | Kernel sysfs |
| Per-process usage | Supported | Not available |
| VRAM usage | Supported | Not applicable; unified memory |
| Power draw | Supported | Rarely exposed |
| Fan speed | Supported | Not applicable |
| Scope | Container workloads | Whole-device GPU |

Per-process GPU accounting is not possible. Android SoC kernels do not publish
it through sysfs.

The reported utilization covers the entire device, including Android screen
rendering, not just the Debian container. Debian does not perform OpenGL or
Vulkan rendering here, so the figure mostly reflects Android UI work and
hardware codec activity.

When the kernel does not publish a value, `gsmi` prints `unavailable` or
`null` instead of guessing.

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
gsmi --loop 1 --count 10 --format csv > gpu-log.csv
gsmi --format json
```

## Kernel interfaces read

| Kind | Example path |
| --- | --- |
| Qualcomm Adreno | `/sys/class/kgsl/kgsl-3d0` |
| ARM Mali | `/sys/class/misc/mali0/device`, `/sys/class/devfreq/*.mali` |
| Generic devfreq | `/sys/class/devfreq/*gpu*` |
| Temperature | `/sys/class/thermal/thermal_zone*` |

Attribute names differ per kernel. Utilization accepts Qualcomm's
`gpu_busy_percentage`, Mali's `utilisation`, and Samsung Exynos's
`utilization`. Clocks come from `cur_freq`, `max_freq`, or Exynos's `clock`,
with Hz and kHz detected automatically. When `max_freq` is absent, the highest
step in Exynos's `dvfs_table` is used.

## Idle reporting

When the GPU is unused, the kernel powers down the rail and reports a zero
clock. `gsmi` prints `idle` instead of `0MHz` so it does not read like a failed
measurement, and shows the power state as `suspended`. In JSON, `clock_mhz`
becomes `null` so numeric fields stay numeric.

Real-device output (Exynos, Mali-G71):

```text
| GPU                    | Mali-G71 20 cores                            |
| Utilization            | 0%                                           |
| Clock                  | idle                                         |
| Max clock              | 546MHz                                       |
| Governor               | Default                                      |
| Power state            | suspended                                    |
| Temperature            | unavailable                                  |
```

Some devices leave the thermal zone `type` empty, so the GPU zone cannot be
identified and the temperature is reported as `unavailable`.

## Troubleshooting

| Symptom | Cause and action |
| --- | --- |
| `no GPU sysfs node was found` | The kernel exposes no GPU node, or `/sys` is not shared. |
| `Utilization` is `unavailable` | The kernel publishes no utilization attribute; use clock and temperature. |
| `Temperature` is `unavailable` | No thermal zone is named after the GPU. |

```sh
gsmi --format json
ls -l /sys/class/devfreq/ 2>/dev/null
ls -l /sys/class/kgsl/ 2>/dev/null
grep -H . /sys/class/thermal/thermal_zone*/type 2>/dev/null
```

To reduce GPU load, move video encoding and decoding onto the hardware codec.
See the [FFmpeg hardware codec guide](ffmpeg-hardware-codec.md).
