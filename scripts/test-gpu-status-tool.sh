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
    sed -e "s#/sys/#$fixture/sys/#g" "$source_script" > "$output"
    chmod 0755 "$output"
}

# Qualcomm Adreno style node.
qualcomm="$work_dir/qualcomm"
mkdir -p "$qualcomm/sys/class/kgsl/kgsl-3d0" \
    "$qualcomm/sys/class/thermal/thermal_zone0"
printf '%s\n' 'Adreno540' > "$qualcomm/sys/class/kgsl/kgsl-3d0/gpu_model"
printf '%s\n' '37 %' > "$qualcomm/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"
printf '%s\n' '710000000' > "$qualcomm/sys/class/kgsl/kgsl-3d0/cur_freq"
printf '%s\n' '710000000' > "$qualcomm/sys/class/kgsl/kgsl-3d0/max_freq"
printf '%s\n' 'msm-adreno-tz' > "$qualcomm/sys/class/kgsl/kgsl-3d0/governor"
printf '%s\n' 'active' > "$qualcomm/sys/class/kgsl/kgsl-3d0/runtime_status"
printf '%s\n' 'gpu-usr' > "$qualcomm/sys/class/thermal/thermal_zone0/type"
printf '%s\n' '41200' > "$qualcomm/sys/class/thermal/thermal_zone0/temp"

make_variant "$qualcomm" "$work_dir/gsmi-qualcomm"
output="$("$work_dir/gsmi-qualcomm" --format json)"
grep -Fq '"name":"Adreno540"' <<<"$output"
grep -Fq '"utilization_percent":37' <<<"$output"
grep -Fq '"clock_mhz":710' <<<"$output"
grep -Fq '"governor":"msm-adreno-tz"' <<<"$output"
grep -Fq '"temperature_c":41.2' <<<"$output"

table="$("$work_dir/gsmi-qualcomm")"
grep -Fq 'DawnShell GPU status (gsmi)' <<<"$table"
grep -Fq '37%' <<<"$table"
grep -Fq '710MHz' <<<"$table"

csv="$("$work_dir/gsmi-qualcomm" --format csv)"
grep -Fq 'timestamp,name,utilization_percent' <<<"$csv"
grep -Fq ',Adreno540,37,710,710,msm-adreno-tz,active,41.2' <<<"$csv"

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
sparse="$work_dir/sparse"
mkdir -p "$sparse/sys/class/devfreq/gpu0"
printf '%s\n' '400000000' > "$sparse/sys/class/devfreq/gpu0/cur_freq"
make_variant "$sparse" "$work_dir/gsmi-sparse"
output="$("$work_dir/gsmi-sparse" --format json)"
grep -Fq '"utilization_percent":null' <<<"$output"
grep -Fq '"clock_mhz":400' <<<"$output"
grep -Fq '"temperature_c":null' <<<"$output"

# No GPU node at all must fail loudly with actionable guidance.
empty="$work_dir/empty"
mkdir -p "$empty/sys/class"
make_variant "$empty" "$work_dir/gsmi-empty"
if "$work_dir/gsmi-empty" >/dev/null 2>&1; then
    echo 'FAIL: gsmi reported success without a GPU node' >&2
    exit 1
fi

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
done
grep -Fq 'gpu-status-tool.md' "$repo_dir/README.md"
grep -Fq 'gpu-status-tool.ko.md' "$repo_dir/README.ko.md"
grep -Fq 'dawnshell_gpu_status_body' \
    "$repo_dir/app/src/main/res/values/strings.xml" \
    "$repo_dir/app/src/main/res/values-ko/strings.xml" \
    "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootActivity.java"

echo 'PASS: gsmi reports Qualcomm, Mali, and sparse kernels without guessing'
