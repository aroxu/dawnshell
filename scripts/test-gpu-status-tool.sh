#!/usr/bin/env bash
# Pins gsmi against synthetic Qualcomm and Mali sysfs layouts so a kernel
# that publishes different attribute names is caught before shipping.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_script="$repo_dir/app/src/main/assets/bfu/gsmi.sh"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
test -f "$source_script"

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

# Rewrite the absolute sysfs roots so the harness can supply fixtures.
make_variant() {
    local fixture="$1"
    local output="$2"
    sed -e "s#/sys/#$fixture/sys/#g" \
        -e "s#/proc/#$fixture/proc/#g" "$source_script" > "$output"
    chmod 0755 "$output"
}

# Qualcomm Adreno style node.
qualcomm="$work_dir/qualcomm"
mkdir -p "$qualcomm/sys/class/kgsl/kgsl-3d0" \
    "$qualcomm/sys/class/thermal/thermal_zone0" \
    "$qualcomm/sys/class/devfreq/soc-qcom-venus" \
    "$qualcomm/proc/1234"
printf '%s\n' 'Adreno540' > "$qualcomm/sys/class/kgsl/kgsl-3d0/gpu_model"
printf '%s\n' '37 %' > "$qualcomm/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"
printf '%s\n' '710000000' > "$qualcomm/sys/class/kgsl/kgsl-3d0/cur_freq"
printf '%s\n' '710000000' > "$qualcomm/sys/class/kgsl/kgsl-3d0/max_freq"
printf '%s\n' 'msm-adreno-tz' > "$qualcomm/sys/class/kgsl/kgsl-3d0/governor"
printf '%s\n' 'active' > "$qualcomm/sys/class/kgsl/kgsl-3d0/runtime_status"
printf '%s\n' 'gpu-usr' > "$qualcomm/sys/class/thermal/thermal_zone0/type"
printf '%s\n' '41200' > "$qualcomm/sys/class/thermal/thermal_zone0/temp"
printf '%s\n' 'Qualcomm Venus' > "$qualcomm/sys/class/devfreq/soc-qcom-venus/name"
printf '%s\n' '66' > "$qualcomm/sys/class/devfreq/soc-qcom-venus/load"
printf '%s\n' '444000000' > "$qualcomm/sys/class/devfreq/soc-qcom-venus/cur_freq"
printf '%s\n' '600000000' > "$qualcomm/sys/class/devfreq/soc-qcom-venus/max_freq"
printf '%s\0' /usr/local/bin/dawnshell-codec pipe encode avc \
    1920 1080 30 4000000 > "$qualcomm/proc/1234/cmdline"

make_variant "$qualcomm" "$work_dir/gsmi-qualcomm"
output="$("$work_dir/gsmi-qualcomm" --format json)"
grep -Fq '"name":"Adreno540"' <<<"$output"
grep -Fq '"utilization_percent":37' <<<"$output"
grep -Fq '"clock_mhz":710' <<<"$output"
grep -Fq '"governor":"msm-adreno-tz"' <<<"$output"
grep -Fq '"temperature_c":41.2' <<<"$output"
grep -Fq '"video_accelerator":"Qualcomm Venus"' <<<"$output"
grep -Fq '"codec_activity":"active"' <<<"$output"
grep -Fq '"codec_clients":1' <<<"$output"
grep -Fq '"codec_encode_clients":1' <<<"$output"
grep -Fq '"codec_utilization_percent":66' <<<"$output"
grep -Fq '"codec_clock_mhz":444' <<<"$output"

table="$("$work_dir/gsmi-qualcomm")"
grep -Fq 'DawnShell accelerator status (gsmi)' <<<"$table"
grep -Fq '3D utilization' <<<"$table"
grep -Fq 'Video accelerator' <<<"$table"
grep -Fq 'Codec activity' <<<"$table"
grep -Fq 'encode=1 decode=0 transcode=0' <<<"$table"
grep -Fq 'MediaCodec uses a dedicated video engine, not the 3D GPU.' <<<"$table"
grep -Fq '37%' <<<"$table"
grep -Fq '710MHz' <<<"$table"

csv="$("$work_dir/gsmi-qualcomm" --format csv)"
grep -Fq 'timestamp,name,utilization_percent' <<<"$csv"
grep -Fq ',Adreno540,37,710,710,msm-adreno-tz,active,41.2,active,1,1,0,0,66,444,600' <<<"$csv"

# ARM Mali style devfreq node, which uses different attribute names.
mali="$work_dir/mali"
mkdir -p "$mali/sys/class/devfreq/mali0-gpu" \
    "$mali/sys/class/thermal/thermal_zone3"
printf '%s\n' '52' > "$mali/sys/class/devfreq/mali0-gpu/utilisation"
printf '%s\n' '546000000' > "$mali/sys/class/devfreq/mali0-gpu/cur_freq"
printf '%s\n' '850000000' > "$mali/sys/class/devfreq/mali0-gpu/max_freq"
printf '%s\n' 'simple_ondemand' > "$mali/sys/class/devfreq/mali0-gpu/governor"
printf '%s\n' 'MALI-G71' > "$mali/sys/class/thermal/thermal_zone3/type"
printf '%s\n' '48' > "$mali/sys/class/thermal/thermal_zone3/temp"

make_variant "$mali" "$work_dir/gsmi-mali"
output="$("$work_dir/gsmi-mali" --format json)"
grep -Fq '"utilization_percent":52' <<<"$output"
grep -Fq '"clock_mhz":546' <<<"$output"
grep -Fq '"max_clock_mhz":850' <<<"$output"
grep -Fq '"governor":"simple_ondemand"' <<<"$output"
grep -Fq '"temperature_c":48.0' <<<"$output"

# A kernel that publishes the node but not utilization must say so rather
# than invent a number.
# Samsung Exynos Mali, verified on a real device: different attribute names,
# kHz clocks, an empty thermal type, and a powered-down GPU reporting zero.
exynos="$work_dir/exynos"
mkdir -p "$exynos/sys/class/misc/mali0/device" \
    "$exynos/sys/class/thermal/thermal_zone0"
printf 'Mali-G71 20 cores r0p0 0x60A0\n' \
    > "$exynos/sys/class/misc/mali0/device/gpuinfo"
printf '0\n' > "$exynos/sys/class/misc/mali0/device/clock"
printf '0\n' > "$exynos/sys/class/misc/mali0/device/utilization"
printf '0\n' > "$exynos/sys/class/misc/mali0/device/power_state"
printf 'Default\n' > "$exynos/sys/class/misc/mali0/device/dvfs_governor"
printf ' 546000 455000 385000 338000 260000\n' \
    > "$exynos/sys/class/misc/mali0/device/dvfs_table"
printf '\n' > "$exynos/sys/class/thermal/thermal_zone0/type"

make_variant "$exynos" "$work_dir/gsmi-exynos"
output="$("$work_dir/gsmi-exynos" --format json)"
grep -Fq '"name":"Mali-G71 20 cores"' <<<"$output"
grep -Fq '"utilization_percent":0' <<<"$output"
grep -Fq '"max_clock_mhz":546' <<<"$output"
grep -Fq '"governor":"Default"' <<<"$output"
grep -Fq '"power_state":"suspended"' <<<"$output"
# A suspended GPU must not report 0 MHz as if it were a measurement, and JSON
# must keep numeric fields numeric.
grep -Fq '"clock_mhz":null' <<<"$output"
table="$("$work_dir/gsmi-exynos")"
grep -Fq '| 3D clock               | idle' <<<"$table"
grep -Fq '546MHz' <<<"$table"
if grep -Fq 'idleMHz' <<<"$table"; then
    echo 'FAIL: a state was formatted as a frequency' >&2
    exit 1
fi

sparse="$work_dir/sparse"
mkdir -p "$sparse/sys/class/devfreq/gpu0"
printf '%s\n' '400000000' > "$sparse/sys/class/devfreq/gpu0/cur_freq"
make_variant "$sparse" "$work_dir/gsmi-sparse"
output="$("$work_dir/gsmi-sparse" --format json)"
grep -Fq '"utilization_percent":null' <<<"$output"
grep -Fq '"clock_mhz":400' <<<"$output"
grep -Fq '"temperature_c":null' <<<"$output"

# Codec activity remains useful even when a kernel exposes no 3D GPU node.
empty="$work_dir/empty"
mkdir -p "$empty/sys/class" "$empty/proc"
make_variant "$empty" "$work_dir/gsmi-empty"
output="$("$work_dir/gsmi-empty" --format json)"
grep -Fq '"name":"unavailable"' <<<"$output"
grep -Fq '"codec_activity":"idle"' <<<"$output"
grep -Fq '"codec_utilization_percent":null' <<<"$output"

# Argument validation must reject values that would loop forever or misreport.
for invalid in '--format xml' '--loop 0' '--loop abc' '--count 3'; do
    # shellcheck disable=SC2086 # Intentional word splitting of the test case.
    if "$work_dir/gsmi-qualcomm" $invalid >/dev/null 2>&1; then
        echo "FAIL: gsmi accepted invalid arguments: $invalid" >&2
        exit 1
    fi
done

# Bounded sampling must stop on its own.
samples="$("$work_dir/gsmi-qualcomm" --format csv --loop 1 --count 2 | grep -c ',Adreno540,')"
[[ "$samples" == 2 ]]

# The configurator must install and verify the tool.
grep -Fq 'dawnshell-gsmi' "$configurator"
grep -Fq '[ -x /usr/local/bin/gsmi ]' "$configurator"
grep -Fq 'gpu_status_tool=/usr/local/bin/gsmi' "$configurator"
grep -Fq 'bfu/gsmi.sh' "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"

# The documented limits must stay recorded, since a whole-device utilization
# figure is easy to mistake for a per-container measurement.
for gpu_doc in "$repo_dir/docs/gpu-status-tool.md" \
        "$repo_dir/docs/gpu-status-tool.ko.md"; do
    test -f "$gpu_doc"
    grep -Fq 'nvidia-smi' "$gpu_doc"
    grep -Fq 'kgsl' "$gpu_doc"
    grep -Fq 'devfreq' "$gpu_doc"
    grep -Fq 'thermal_zone' "$gpu_doc"
    grep -Fq 'MediaCodec' "$gpu_doc"
done
grep -Fq 'gpu-status-tool.md' "$repo_dir/README.md"
grep -Fq 'gpu-status-tool.ko.md' "$repo_dir/README.ko.md"
grep -Fq 'dawnshell_gpu_status_body' \
    "$repo_dir/app/src/main/res/values/strings.xml" \
    "$repo_dir/app/src/main/res/values-ko/strings.xml" \
    "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootActivity.java"

echo 'PASS: gsmi separates 3D GPU and MediaCodec video activity without guessing'
