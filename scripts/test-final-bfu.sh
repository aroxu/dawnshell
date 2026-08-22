#!/usr/bin/env bash
set -euo pipefail

: "${BFU_PHONE_HOST:?Set BFU_PHONE_HOST to the phone IP address reachable before unlock}"
: "${BFU_SSH_KEY:?Set BFU_SSH_KEY to the dedicated BFU SSH private key}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cycles="${BFU_CYCLES:-10}"
results_dir="${BFU_RESULTS_DIR:-$repo_dir/test-results/bfu-$(date -u +%Y%m%dT%H%M%SZ)}"

for tool in adb awk grep head sed sha256sum tee tr unzip; do
  command -v "$tool" >/dev/null || {
    echo "Missing host tool: $tool" >&2
    exit 2
  }
done

case "$cycles" in
  ''|*[!0-9]*) echo "BFU_CYCLES must be a positive integer" >&2; exit 2 ;;
esac
(( cycles > 0 )) || {
  echo "BFU_CYCLES must be greater than zero" >&2
  exit 2
}

mkdir -p "$results_dir"
summary="$results_dir/cycles.tsv"
printf 'cycle\tandroid_boot_id\tboot_app_pid\ttotal_pss_kib\ttotal_rss_kib\tsupervisor_pid\tinit_host_pid\tsystemd_count\n' \
  > "$summary"

preflight="$results_dir/preflight.txt"
{
  echo "crypto_type=$(adb shell getprop ro.crypto.type | tr -d '\r')"
  echo "cpu_abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  adb shell dumpsys package com.termux.boot \
    | tr -d '\r' \
    | grep -E 'userId=|dataDir=|targetSdk='
  adb shell dumpsys package com.termux \
    | tr -d '\r' \
    | grep -E 'userId=|dataDir=|targetSdk='
} | tee "$preflight"
grep -Fq 'crypto_type=file' "$preflight"
grep -Fq 'cpu_abi=arm64-v8a' "$preflight"
target_count="$(grep -Fc 'targetSdk=28' "$preflight" || true)"
[[ "$target_count" -ge 2 ]] || {
  echo "FAIL: both Termux packages must report targetSdk=28" >&2
  exit 2
}

boot_apk="$repo_dir/dist/termux-boot_0.8.1_bfu_debug.apk"
termux_apk="$repo_dir/dist/termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk"
for apk in "$boot_apk" "$termux_apk"; do
  [[ -f "$apk" ]] || {
    echo "FAIL: missing staged APK: $apk" >&2
    exit 2
  }
done
expected_helper_hash="DD5E7CB52AC785F4AA6D04694ED6D3DB762D93820E274DD18AB36AC1FB7C6231"
actual_boot_hash="$(sha256sum "$boot_apk" | awk '{print toupper($1)}')"
actual_termux_hash="$(sha256sum "$termux_apk" | awk '{print toupper($1)}')"
embedded_helper_hash="$(unzip -p "$boot_apk" \
  assets/bfu/bin/bfu-namespace-probe-arm64 \
  | sha256sum | awk '{print toupper($1)}')"
[[ "$embedded_helper_hash" = "$expected_helper_hash" ]] || {
  echo "FAIL: staged Termux:Boot APK embeds the wrong BFU helper" >&2
  exit 2
}

artifact_evidence="$results_dir/artifacts.tsv"
printf 'package\tlocal_sha256\tinstalled_sha256\n' > "$artifact_evidence"

verify_installed_apk() {
  local package_name="$1"
  local local_hash="$2"
  local installed_path installed_apk installed_hash
  installed_path="$(adb shell pm path "$package_name" \
    | tr -d '\r' | sed -n 's/^package://p' | head -n 1)"
  [[ -n "$installed_path" ]] || {
    echo "FAIL: could not resolve installed APK for $package_name" >&2
    exit 2
  }
  installed_apk="$results_dir/installed-${package_name//./-}.apk"
  adb pull "$installed_path" "$installed_apk" >/dev/null
  installed_hash="$(sha256sum "$installed_apk" | awk '{print toupper($1)}')"
  printf '%s\t%s\t%s\n' \
    "$package_name" "$local_hash" "$installed_hash" >> "$artifact_evidence"
  [[ "$installed_hash" = "$local_hash" ]] || {
    echo "FAIL: installed $package_name APK differs from local staged artifact" >&2
    echo "local=$local_hash installed=$installed_hash" >&2
    exit 2
  }
}

verify_installed_apk com.termux.boot "$actual_boot_hash"
verify_installed_apk com.termux "$actual_termux_hash"
cat "$artifact_evidence"

for ((cycle = 1; cycle <= cycles; cycle++)); do
  echo "============================================================"
  echo "Final BFU cold cycle $cycle/$cycles"
  cycle_log="$results_dir/cycle-$(printf '%02d' "$cycle").log"
  "$repo_dir/scripts/test-systemd-ssh-bfu.sh" 2>&1 | tee "$cycle_log"

  boot_id="$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r\n')"
  app_pid="$(adb shell pidof com.termux.boot | tr -d '\r\n' || true)"
  meminfo="$(adb shell dumpsys meminfo com.termux.boot 2>/dev/null | tr -d '\r')"
  total_pss="$(printf '%s\n' "$meminfo" \
    | sed -n 's/^ *TOTAL PSS: *\([0-9][0-9]*\).*/\1/p' \
    | head -n 1)"
  total_rss="$(printf '%s\n' "$meminfo" \
    | sed -n 's/^ *TOTAL PSS:.*TOTAL RSS: *\([0-9][0-9]*\).*/\1/p' \
    | head -n 1)"
  state="$(adb exec-out run-as com.termux.boot cat \
    /data/user_de/0/com.termux.boot/files/bfu/run/debian-supervisor.state \
    2>/dev/null | tr -d '\r')"
  supervisor_pid="$(sed -n 's/^supervisor_pid=//p' <<<"$state")"
  init_host_pid="$(sed -n 's/^init_host_pid=//p' <<<"$state")"
  helper="/data/user_de/0/com.termux.boot/files/bfu/bin/bfu-namespace-probe-arm64"
  rootfs="/data/local/debian"
  control="/data/user_de/0/com.termux.boot/files/bfu/run"
  launcher_status="$(adb shell su -c \
    "$helper status $rootfs $control" | tr -d '\r')"
  grep -Fq 'BFU_DEBIAN_RUNNING' <<<"$launcher_status"
  grep -Fq 'namespace_topology_valid=true' <<<"$launcher_status"
  grep -Fq 'network_namespace=android-shared' <<<"$launcher_status"
  device_helper_hash="$(adb exec-out run-as com.termux.boot cat "$helper" \
    | sha256sum | awk '{print toupper($1)}')"
  [[ "$device_helper_hash" = "$expected_helper_hash" ]] || {
    echo "FAIL: provisioned BFU helper does not match the frozen APK" >&2
    exit 8
  }
  # Literal root-side loop; command substitutions must expand on Android.
  # shellcheck disable=SC2016
  systemd_count="$(adb shell su -c 'count=0; for file in /proc/[0-9]*/comm; do [ "$(cat "$file" 2>/dev/null)" = systemd ] && count=$((count + 1)); done; echo "$count"' | tr -d '\r\n')"
  [[ "$systemd_count" = "1" ]] || {
    echo "FAIL: expected exactly one systemd process, found $systemd_count" >&2
    exit 8
  }
  init_comm="$(adb shell su -c "cat /proc/$init_host_pid/comm" | tr -d '\r\n')"
  [[ "$init_comm" = systemd ]]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cycle" "$boot_id" "${app_pid:-unknown}" "${total_pss:-unknown}" \
    "${total_rss:-unknown}" "${supervisor_pid:-unknown}" \
    "${init_host_pid:-unknown}" "$systemd_count" >> "$summary"
done

awk -F '\t' '
  NR == 1 { next }
  $2 in seen { printf "FAIL: repeated Android boot ID on cycles %d and %d\n", seen[$2], $1 > "/dev/stderr"; exit 1 }
  { seen[$2] = $1 }
' "$summary"

if ! awk -F '\t' '
  NR == 1 || $4 !~ /^[0-9]+$/ { next }
  !have { first=$4; last=$4; previous=$4; monotonic=1; have=1; next }
  $4 <= previous { monotonic=0 }
  { previous=$4; last=$4 }
  END { if (have && monotonic && last-first > 32768) exit 1 }
' "$summary"; then
  echo "FAIL: Termux:Boot TOTAL PSS rose monotonically by more than 32 MiB" >&2
  exit 7
fi

echo "============================================================"
echo "Running namespace poweroff/reboot/shutdown isolation checks..."
"$repo_dir/scripts/test-systemd-shutdown-isolation.sh" 2>&1 \
  | tee "$results_dir/shutdown-isolation.log"

cp "$summary" "$results_dir/summary.tsv"
echo "============================================================"
echo "PASS: $cycles BFU cold cycles plus poweroff/reboot/shutdown isolation completed."
echo "Evidence directory: $results_dir"
cat "$summary"
