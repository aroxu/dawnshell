#!/bin/sh
# gsmi - DawnShell graphics and video-accelerator status monitor.
#
# Reads vendor-neutral kernel interfaces exposed under /sys. No GPU vendor
# tooling exists for Android SoCs inside a Debian chroot, so this reports what
# the kernel actually publishes and stays explicit about anything missing.
set -eu
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

interval=
count=
format=table

usage() {
    cat <<'EOF'
usage: gsmi [OPTIONS]

  -l, --loop SECONDS   Refresh every SECONDS (1..3600)
  -n, --count N        Stop after N samples (use with --loop)
      --format FORMAT  table (default), csv, or json
  -h, --help           Show this help

Reports 3D GPU state separately from Android's dedicated MediaCodec video
accelerator. Kernel counters are used when available; active DawnShell codec
clients are detected from /proc without inventing a utilization percentage.
EOF
}

fail() {
    echo "gsmi: $*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -l|--loop)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            interval="$2"
            shift 2
            ;;
        -n|--count)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            count="$2"
            shift 2
            ;;
        --format)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            format="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

case "$format" in
    table|csv|json) ;;
    *) fail "format must be table, csv, or json" ;;
esac
if [ -n "$interval" ]; then
    case "$interval" in
        ''|*[!0-9]*) fail "--loop must be a positive integer" ;;
    esac
    [ "$interval" -ge 1 ] && [ "$interval" -le 3600 ] || \
        fail "--loop must be within 1..3600 seconds"
fi
if [ -n "$count" ]; then
    case "$count" in
        ''|*[!0-9]*) fail "--count must be a positive integer" ;;
    esac
    [ "$count" -ge 1 ] || fail "--count must be at least 1"
    [ -n "$interval" ] || fail "--count requires --loop"
fi

read_first_line() {
    [ -r "$1" ] || return 1
    # A sysfs attribute can fail at read time even when it exists.
    head -n 1 "$1" 2>/dev/null || return 1
}

trim() {
    printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Locate the GPU node without assuming a vendor. Qualcomm exposes kgsl-3d0,
# ARM Mali exposes a mali device, and both usually appear as a devfreq node.
find_gpu_directory() {
    for candidate in \
        /sys/class/kgsl/kgsl-3d0 \
        /sys/devices/platform/soc/*.qcom,kgsl-3d0 \
        /sys/devices/platform/*.kgsl-3d0 \
        /sys/class/misc/mali0/device \
        /sys/devices/platform/*.mali \
        /sys/devices/platform/soc/*.mali \
        /sys/class/devfreq/*.mali \
        /sys/class/devfreq/*gpu* \
        /sys/class/devfreq/*kgsl* ; do
        [ -d "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

gpu_directory="$(find_gpu_directory || true)"

# Video codecs on mobile SoCs normally run on a dedicated accelerator rather
# than the Mali/Adreno 3D GPU. A few kernels expose that block through devfreq,
# using vendor names such as MFC, Venus, VPU, VCodec, VENC, or VDEC.
find_video_directory() {
    for candidate in \
        /sys/class/devfreq/*mfc* \
        /sys/class/devfreq/*venus* \
        /sys/class/devfreq/*vpu* \
        /sys/class/devfreq/*vcodec* \
        /sys/class/devfreq/*venc* \
        /sys/class/devfreq/*vdec* \
        /sys/devices/platform/*mfc*/devfreq/* \
        /sys/devices/platform/*venus*/devfreq/* \
        /sys/devices/platform/*vpu*/devfreq/* \
        /sys/devices/platform/*vcodec*/devfreq/* ; do
        [ -d "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

video_directory="$(find_video_directory || true)"

# Busy percentage. Qualcomm publishes gpu_busy_percentage directly, and Mali
# devfreq nodes publish utilisation, so a single read is enough for both.
# Qualcomm formats the value as "37 %" while Mali reports a bare integer, so
# strip the percent sign and whitespace before validating the number.
parse_percentage() {
    # Implemented with shell builtins and tr so behaviour never depends on
    # whether awk is mawk, busybox awk, or GNU awk.
    candidate="$(printf '%s' "$1" | tr -d '%[:space:]')"
    case "$candidate" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Strip leading zeros without arithmetic surprises, then bound the value.
    candidate="$((candidate + 0))"
    [ "$candidate" -le 100 ] || return 1
    printf '%s\n' "$candidate"
}

read_devfreq_utilization() {
    for base in "$1" "$1/devfreq"/*; do
        [ -d "$base" ] || continue
        if [ -r "$base/gpu_busy_percentage" ]; then
            value="$(read_first_line "$base/gpu_busy_percentage" || true)"
            parsed="$(parse_percentage "${value:-}")"
            [ -z "$parsed" ] || { printf '%s\n' "$parsed"; return 0; }
        fi
        if [ -r "$base/utilisation" ]; then
            value="$(read_first_line "$base/utilisation" || true)"
            parsed="$(parse_percentage "${value:-}")"
            [ -z "$parsed" ] || { printf '%s\n' "$parsed"; return 0; }
        fi
        # Samsung Exynos spells the Mali attribute without the British 's'.
        if [ -r "$base/utilization" ]; then
            value="$(read_first_line "$base/utilization" || true)"
            parsed="$(parse_percentage "${value:-}")"
            [ -z "$parsed" ] || { printf '%s\n' "$parsed"; return 0; }
        fi
        for attribute in busy_percentage busy_percent load; do
            [ -r "$base/$attribute" ] || continue
            value="$(read_first_line "$base/$attribute" || true)"
            parsed="$(parse_percentage "${value:-}" || true)"
            [ -z "$parsed" ] || { printf '%s\n' "$parsed"; return 0; }
        done
    done
    return 1
}

read_attribute() {
    directory="$1"
    shift
    for name in "$@"; do
        for base in "$directory" "$directory/devfreq"/*; do
            [ -d "$base" ] || continue
            if [ -r "$base/$name" ]; then
                value="$(trim "$(read_first_line "$base/$name" || true)")"
                [ -z "$value" ] || { printf '%s\n' "$value"; return 0; }
            fi
        done
    done
    return 1
}

hertz_to_mhz() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    value="$((${1} + 0))"
    # Kernels publish Hz or kHz depending on the driver.
    if [ "$value" -ge 1000000 ]; then
        printf '%s\n' "$((value / 1000000))"
    elif [ "$value" -ge 1000 ]; then
        printf '%s\n' "$((value / 1000))"
    else
        printf '%s\n' "$value"
    fi
}

read_gpu_temperature() {
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "$zone/type" ] || continue
        zone_type="$(trim "$(read_first_line "$zone/type" || true)")"
        # Zone names vary in case across kernels, for example gpu-usr and
        # MALI-G71, so compare in lowercase.
        zone_type="$(printf '%s' "$zone_type" | tr '[:upper:]' '[:lower:]')"
        case "$zone_type" in
            *gpu*|*kgsl*|*mali*|*adreno*) ;;
            *) continue ;;
        esac
        raw="$(trim "$(read_first_line "$zone/temp" || true)")"
        case "$raw" in
            ''|*[!0-9-]*) continue ;;
        esac
        # Kernels report millidegrees or whole degrees. Keep one decimal place
        # using integer arithmetic so no awk implementation is involved.
        case "$raw" in
            -*) continue ;;
        esac
        value="$((raw + 0))"
        if [ "$value" -gt 1000 ]; then
            printf '%s.%s\n' "$((value / 1000))" "$(((value % 1000) / 100))"
        else
            printf '%s.0\n' "$value"
        fi
        return 0
    done
    return 1
}

collect_sample() {
    gpu_name=unavailable
    gpu_busy=unavailable
    gpu_clock=unavailable
    gpu_max_clock=unavailable
    gpu_governor=unavailable
    gpu_temperature=unavailable
    gpu_power_state=unavailable

    [ -n "$gpu_directory" ] || return 1

    gpu_name="$(read_attribute "$gpu_directory" gpu_model gpuclk_name name || true)"
    if [ -z "$gpu_name" ]; then
        # Exynos Mali publishes a descriptive line such as
        # "Mali-G71 20 cores r0p0 0x60A0"; keep the model and core count.
        raw_info="$(read_attribute "$gpu_directory" gpuinfo || true)"
        if [ -n "$raw_info" ]; then
            gpu_name="$(printf '%s' "$raw_info" | cut -d' ' -f1-3)"
        fi
    fi
    if [ -z "$gpu_name" ]; then
        gpu_name="$(basename "$gpu_directory")"
    fi

    value="$(read_devfreq_utilization "$gpu_directory" || true)"
    [ -z "$value" ] || gpu_busy="$value"

    value="$(read_attribute "$gpu_directory" cur_freq gpuclk clkgt_freq clock || true)"
    if [ -n "$value" ]; then
        converted="$(hertz_to_mhz "$value")"
        [ -z "$converted" ] || gpu_clock="$converted"
    fi

    value="$(read_attribute "$gpu_directory" max_freq max_gpuclk || true)"
    if [ -n "$value" ]; then
        converted="$(hertz_to_mhz "$value")"
        [ -z "$converted" ] || gpu_max_clock="$converted"
    fi
    if [ "$gpu_max_clock" = unavailable ]; then
        # Exynos publishes the supported steps in dvfs_table, highest first.
        value="$(read_attribute "$gpu_directory" dvfs_table || true)"
        if [ -n "$value" ]; then
            for step in $value; do
                converted="$(hertz_to_mhz "$step" || true)"
                [ -z "$converted" ] || { gpu_max_clock="$converted"; break; }
            done
        fi
    fi

    value="$(read_attribute "$gpu_directory" governor devfreq_governor dvfs_governor || true)"
    [ -z "$value" ] || gpu_governor="$value"

    value="$(read_attribute "$gpu_directory" runtime_status || true)"
    [ -z "$value" ] || gpu_power_state="$value"
    if [ "$gpu_power_state" = unavailable ]; then
        # Exynos Mali reports a numeric rail state: 0 is powered down.
        value="$(read_attribute "$gpu_directory" power_state || true)"
        case "$value" in
            0) gpu_power_state=suspended ;;
            1) gpu_power_state=active ;;
            '') ;;
            *) gpu_power_state="$value" ;;
        esac
    fi
    # A powered-down GPU reports a zero clock. Say so instead of printing 0MHz,
    # which reads like a measurement failure.
    if [ "$gpu_clock" = 0 ] && [ "$gpu_power_state" = suspended ]; then
        gpu_clock=idle
    fi

    value="$(read_gpu_temperature || true)"
    [ -z "$value" ] || gpu_temperature="$value"

    return 0
}

collect_video_sample() {
    video_name='Android MediaCodec video accelerator'
    video_busy=unavailable
    video_clock=unavailable
    video_max_clock=unavailable
    codec_activity=idle
    codec_clients=0
    codec_encode_clients=0
    codec_decode_clients=0
    codec_transcode_clients=0

    if [ -n "$video_directory" ]; then
        value="$(read_attribute "$video_directory" name model device_name || true)"
        [ -z "$value" ] || video_name="$value"
        value="$(read_devfreq_utilization "$video_directory" || true)"
        [ -z "$value" ] || video_busy="$value"
        value="$(read_attribute "$video_directory" cur_freq clock freq || true)"
        if [ -n "$value" ]; then
            converted="$(hertz_to_mhz "$value" || true)"
            [ -z "$converted" ] || video_clock="$converted"
        fi
        value="$(read_attribute "$video_directory" max_freq max_clock || true)"
        if [ -n "$value" ]; then
            converted="$(hertz_to_mhz "$value" || true)"
            [ -z "$converted" ] || video_max_clock="$converted"
        fi
    fi

    # Each hardware operation owns a private static client and bionic worker.
    # Count the client only; counting the worker too would double every job.
    for process in /proc/[0-9]*; do
        [ -r "$process/cmdline" ] || continue
        command="$(tr '\000' ' ' < "$process/cmdline" 2>/dev/null || true)"
        case "$command" in
            *"dawnshell-codec pipe encode "*|*"dawnshell-codec encode-test "*)
                codec_encode_clients=$((codec_encode_clients + 1))
                ;;
            *"dawnshell-codec pipe decode "*|*"dawnshell-codec decode-test "*)
                codec_decode_clients=$((codec_decode_clients + 1))
                ;;
            *"dawnshell-codec transcode "*|*"dawnshell-codec transcode-test "*)
                codec_transcode_clients=$((codec_transcode_clients + 1))
                ;;
        esac
    done
    codec_clients=$((codec_encode_clients + codec_decode_clients
        + codec_transcode_clients))
    if [ "$codec_clients" -gt 0 ]; then
        codec_activity=active
    elif [ "$video_busy" != unavailable ] && [ "$video_busy" -gt 0 ]; then
        codec_activity=active
    fi
}

print_table() {
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    busy_display="$gpu_busy"
    [ "$busy_display" = unavailable ] || busy_display="$gpu_busy%"
    # Only append the unit to an actual measurement; idle and unavailable are
    # states, not frequencies.
    clock_display="$gpu_clock"
    case "$clock_display" in
        unavailable|idle) ;;
        *) clock_display="${gpu_clock}MHz" ;;
    esac
    max_clock_display="$gpu_max_clock"
    case "$max_clock_display" in
        unavailable|idle) ;;
        *) max_clock_display="${gpu_max_clock}MHz" ;;
    esac
    temperature_display="$gpu_temperature"
    [ "$temperature_display" = unavailable ] || temperature_display="${gpu_temperature}C"
    video_busy_display="$video_busy"
    [ "$video_busy_display" = unavailable ] || video_busy_display="$video_busy%"
    video_clock_display="$video_clock"
    [ "$video_clock_display" = unavailable ] || video_clock_display="${video_clock}MHz"
    video_max_clock_display="$video_max_clock"
    [ "$video_max_clock_display" = unavailable ] || \
        video_max_clock_display="${video_max_clock}MHz"
    codec_workloads="encode=$codec_encode_clients decode=$codec_decode_clients transcode=$codec_transcode_clients"

    printf '%s\n' "$timestamp   DawnShell accelerator status (gsmi)"
    printf '%s\n' '+-----------------------------------------------------------------------+'
    printf '| %-22s | %-44s |\n' '3D GPU' "$gpu_name"
    printf '| %-22s | %-44s |\n' '3D utilization' "$busy_display"
    printf '| %-22s | %-44s |\n' '3D clock' "$clock_display"
    printf '| %-22s | %-44s |\n' '3D max clock' "$max_clock_display"
    printf '| %-22s | %-44s |\n' '3D governor' "$gpu_governor"
    printf '| %-22s | %-44s |\n' '3D power state' "$gpu_power_state"
    printf '| %-22s | %-44s |\n' '3D temperature' "$temperature_display"
    printf '%s\n' '+-----------------------------------------------------------------------+'
    printf '| %-22s | %-44s |\n' 'Video accelerator' "$video_name"
    printf '| %-22s | %-44s |\n' 'Codec activity' "$codec_activity"
    printf '| %-22s | %-44s |\n' 'Codec clients' "$codec_clients"
    printf '| %-22s | %-44s |\n' 'Codec workloads' "$codec_workloads"
    printf '| %-22s | %-44s |\n' 'Codec utilization' "$video_busy_display"
    printf '| %-22s | %-44s |\n' 'Codec clock' "$video_clock_display"
    printf '| %-22s | %-44s |\n' 'Codec max clock' "$video_max_clock_display"
    printf '%s\n' '+-----------------------------------------------------------------------+'
    printf '%s\n' 'Sources: kernel sysfs and DawnShell client processes in /proc.'
    printf '%s\n' 'MediaCodec uses a dedicated video engine, not the 3D GPU.'
    if [ "$video_busy" = unavailable ]; then
        printf '%s\n' 'Codec utilization: unavailable because this kernel exports no VPU busy counter.'
    fi
}

print_csv() {
    if [ "${csv_header_printed:-0}" = 0 ]; then
        printf '%s\n' 'timestamp,name,utilization_percent,clock_mhz,max_clock_mhz,governor,power_state,temperature_c,codec_activity,codec_clients,codec_encode_clients,codec_decode_clients,codec_transcode_clients,codec_utilization_percent,codec_clock_mhz,codec_max_clock_mhz'
        csv_header_printed=1
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$gpu_name" "$gpu_busy" \
        "$gpu_clock" "$gpu_max_clock" "$gpu_governor" "$gpu_power_state" \
        "$gpu_temperature" "$codec_activity" "$codec_clients" \
        "$codec_encode_clients" "$codec_decode_clients" \
        "$codec_transcode_clients" "$video_busy" "$video_clock" \
        "$video_max_clock"
}

json_value() {
    case "$1" in
        unavailable|idle) printf 'null' ;;
        ''|*[!0-9.]*) printf '"%s"' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

print_json() {
    printf '{"timestamp":"%s","name":"%s"' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$gpu_name"
    printf ',"utilization_percent":'; json_value "$gpu_busy"
    printf ',"clock_mhz":'; json_value "$gpu_clock"
    printf ',"max_clock_mhz":'; json_value "$gpu_max_clock"
    printf ',"governor":'; json_value "$gpu_governor"
    printf ',"power_state":'; json_value "$gpu_power_state"
    printf ',"temperature_c":'; json_value "$gpu_temperature"
    printf ',"sysfs_path":'; json_value "${gpu_directory:-unavailable}"
    printf ',"video_accelerator":"%s"' "$video_name"
    printf ',"codec_activity":"%s"' "$codec_activity"
    printf ',"codec_clients":%s' "$codec_clients"
    printf ',"codec_encode_clients":%s' "$codec_encode_clients"
    printf ',"codec_decode_clients":%s' "$codec_decode_clients"
    printf ',"codec_transcode_clients":%s' "$codec_transcode_clients"
    printf ',"codec_utilization_percent":'; json_value "$video_busy"
    printf ',"codec_clock_mhz":'; json_value "$video_clock"
    printf ',"codec_max_clock_mhz":'; json_value "$video_max_clock"
    printf ',"codec_sysfs_path":'; json_value "${video_directory:-unavailable}"
    printf '}\n'
}

emit_sample() {
    case "$format" in
        table) print_table ;;
        csv) print_csv ;;
        json) print_json ;;
    esac
}

samples=0
while : ; do
    collect_sample || true
    collect_video_sample
    emit_sample
    samples=$((samples + 1))
    [ -n "$interval" ] || break
    if [ -n "$count" ] && [ "$samples" -ge "$count" ]; then
        break
    fi
    sleep "$interval"
done
