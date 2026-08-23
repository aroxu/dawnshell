#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac

: "${BFU_PHONE_HOST:?Set BFU_PHONE_HOST to the phone IP address reachable before unlock}"
: "${BFU_SSH_KEY:?Set BFU_SSH_KEY to the dedicated BFU SSH private key}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cycles="${BFU_CYCLES:-5}"
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
crypto_state="$(adb shell getprop ro.crypto.state | tr -d '\r')"
crypto_type="$(adb shell getprop ro.crypto.type | tr -d '\r')"
cpu_abi="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
bfu_app_id="$(adb shell dumpsys package me.aroxu.dawnshell \
  | tr -d '\r' | sed -n 's/^ *appId=\([0-9][0-9]*\).*$/\1/p' | sed -n '1p')"
{
  echo "reported_model=$(adb shell getprop ro.product.model | tr -d '\r')"
  echo "reported_device=$(adb shell getprop ro.product.device | tr -d '\r')"
  echo "crypto_state=$crypto_state"
  echo "crypto_type=${crypto_type:-<unset>}"
  echo "cpu_abi=$cpu_abi"
  echo "dawnshell_app_id=$bfu_app_id"
  adb shell dumpsys package me.aroxu.dawnshell \
    | tr -d '\r' | grep -E 'appId=|dataDir=|targetSdk='
} | tee "$preflight"
[[ "$crypto_state" = "encrypted" ]] || {
  echo "FAIL: Android data encryption is not reported as active" >&2
  exit 2
}
if [[ -n "$crypto_type" && "$crypto_type" != "file" ]]; then
  echo "FAIL: ROM reports a non-FBE crypto type: $crypto_type" >&2
  exit 2
fi
if [[ -z "$crypto_type" ]]; then
  echo "NOTE: ro.crypto.type is unset; fresh locked-state CE-isolation evidence is mandatory."
fi
case "$cpu_abi" in
  armeabi-v7a|arm64-v8a|x86_64) ;;
  *) echo "FAIL: unsupported Android ABI: $cpu_abi" >&2; exit 2 ;;
esac
[[ -n "$bfu_app_id" ]] || {
  echo "FAIL: standalone DawnShell app is not installed" >&2
  exit 2
}
target_count="$(grep -Fc 'targetSdk=28' "$preflight" || true)"
[[ "$target_count" -ge 1 ]] || {
  echo "FAIL: DawnShell must report targetSdk=28" >&2
  exit 2
}

bfu_apk="$repo_dir/dist/dawnshell_0.2.2_debug.apk"
[[ -f "$bfu_apk" ]] || {
  echo "FAIL: missing staged APK: $bfu_apk" >&2
  exit 2
}
actual_bfu_hash="$(sha256sum "$bfu_apk" | awk '{print toupper($1)}')"
embedded_helper_hash="$(unzip -p "$bfu_apk" \
  "assets/bfu/bin/$cpu_abi/bfu-namespace-probe" \
  | sha256sum | awk '{print toupper($1)}')"

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
  adb_destination="$installed_apk"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) adb_destination="$(cygpath -w "$installed_apk")" ;;
  esac
  adb pull "$installed_path" "$adb_destination" >/dev/null
  installed_hash="$(sha256sum "$installed_apk" | awk '{print toupper($1)}')"
  printf '%s\t%s\t%s\n' \
    "$package_name" "$local_hash" "$installed_hash" >> "$artifact_evidence"
  [[ "$installed_hash" = "$local_hash" ]] || {
    echo "FAIL: installed $package_name APK differs from local staged artifact" >&2
    echo "local=$local_hash installed=$installed_hash" >&2
    exit 2
  }
}

verify_installed_apk me.aroxu.dawnshell "$actual_bfu_hash"
cat "$artifact_evidence"

for ((cycle = 1; cycle <= cycles; cycle++)); do
  echo "============================================================"
  echo "Final BFU cold cycle $cycle/$cycles"
  cycle_log="$results_dir/cycle-$(printf '%02d' "$cycle").log"
  "$repo_dir/scripts/test-systemd-ssh-bfu.sh" 2>&1 | tee "$cycle_log"

  boot_id="$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r\n')"
  app_pid="$(adb shell pidof me.aroxu.dawnshell | tr -d '\r\n' || true)"
  meminfo="$(adb shell dumpsys meminfo me.aroxu.dawnshell 2>/dev/null | tr -d '\r')"
  total_pss="$(printf '%s\n' "$meminfo" \
    | sed -n 's/^ *TOTAL PSS: *\([0-9][0-9]*\).*/\1/p' \
    | head -n 1)"
  total_rss="$(printf '%s\n' "$meminfo" \
    | sed -n 's/^ *TOTAL PSS:.*TOTAL RSS: *\([0-9][0-9]*\).*/\1/p' \
    | head -n 1)"
  state="$(adb exec-out run-as me.aroxu.dawnshell cat \
    /data/user_de/0/me.aroxu.dawnshell/files/bfu/run/debian-supervisor.state \
    2>/dev/null | tr -d '\r')"
  supervisor_pid="$(sed -n 's/^supervisor_pid=//p' <<<"$state")"
  init_host_pid="$(sed -n 's/^init_host_pid=//p' <<<"$state")"
  helper="/data/user_de/0/me.aroxu.dawnshell/files/bfu/bin/bfu-namespace-probe"
  rootfs="/data/local/debian"
  control="/data/user_de/0/me.aroxu.dawnshell/files/bfu/run"
  launcher_status="$(adb shell su -c \
    "$helper status $rootfs $control" | tr -d '\r')"
  grep -Fq 'BFU_DEBIAN_RUNNING' <<<"$launcher_status"
  grep -Fq 'namespace_topology_valid=true' <<<"$launcher_status"
  grep -Fq 'ipc_namespace=android-shared' <<<"$launcher_status"
  grep -Fq 'network_namespace=android-shared network_mode=shared-nic' <<<"$launcher_status"
  grep -Eq 'cgroup_mode=(v1|v2)' <<<"$launcher_status"
  device_helper_hash="$(adb exec-out run-as me.aroxu.dawnshell cat "$helper" \
    | sha256sum | awk '{print toupper($1)}')"
  [[ "$device_helper_hash" = "$embedded_helper_hash" ]] || {
    echo "FAIL: provisioned BFU helper does not match the installed APK artifact" >&2
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
  echo "FAIL: DawnShell TOTAL PSS rose monotonically by more than 32 MiB" >&2
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
