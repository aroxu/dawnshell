#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac

: "${BFU_PHONE_HOST:?Set BFU_PHONE_HOST to the phone IP address reachable before unlock}"
: "${BFU_SSH_KEY:?Set BFU_SSH_KEY to the local private key matching the configured public key}"

if [[ "${BFU_REQUIRE_CODEC_PERFORMANCE:-0}" == "1"
      && "${BFU_REQUIRE_HARDWARE_CODEC:-0}" != "1" ]]; then
  echo "BFU_REQUIRE_CODEC_PERFORMANCE=1 requires BFU_REQUIRE_HARDWARE_CODEC=1" >&2
  exit 2
fi

ssh_user="${BFU_SSH_USER:-debian}"
ssh_port="${BFU_SSH_PORT:-22}"
wait_seconds="${BFU_SSH_WAIT_SECONDS:-120}"
expect_ce_override="${BFU_EXPECT_CE_READABLE_OVERRIDE:-0}"
operation_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu-operation.log"
locked_boot_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu-boot.log"
root_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu-root.log"
rootfs_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu-rootfs.log"
runtime_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu-debian-runtime.log"
lifecycle_status_path="/data/user_de/0/me.aroxu.dawnshell/files/debian-lifecycle.status"
lifecycle_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu/run/debian-lifecycle.log"
ce_isolation_log_path="/data/user_de/0/me.aroxu.dawnshell/files/bfu-ce-isolation.log"

[[ -f "$BFU_SSH_KEY" ]] || {
  echo "Private key does not exist: $BFU_SSH_KEY" >&2
  exit 2
}

for tool in adb grep head mktemp sed ssh tr; do
  command -v "$tool" >/dev/null || {
    echo "Missing host tool: $tool" >&2
    exit 2
  }
done

android_abi="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$android_abi" in
  armeabi-v7a) debian_arch=armhf ;;
  arm64-v8a) debian_arch=arm64 ;;
  x86_64) debian_arch=amd64 ;;
  *) echo "Unsupported Android ABI: $android_abi" >&2; exit 2 ;;
esac

read_boot_de_file() {
  adb exec-out run-as me.aroxu.dawnshell cat "$1" 2>/dev/null | tr -d '\r'
}

fresh_log_lines() {
  local path="$1"
  local previous_count="$2"
  local contents
  contents="$(read_boot_de_file "$path" || true)"
  [[ -n "$contents" ]] || return 0
  printf '%s\n' "$contents" | sed -n "$((previous_count + 1)),\$p"
}

require_one_fresh_record() {
  local label="$1"
  local marker="$2"
  local contents="$3"
  local count
  count="$(grep -Fc "$marker" <<<"$contents" || true)"
  [[ "$count" == "1" ]] || {
    echo "FAIL: expected one fresh $label record, observed $count" >&2
    exit 7
  }
}

known_hosts="$(mktemp)"
codec_hold_started=0
cleanup() {
  if [[ "$codec_hold_started" == "1" ]]; then
    ssh "${ssh_args[@]}" "$ssh_user@$BFU_PHONE_HOST" \
      'systemctl stop dawnshell-codec-unlock-hold.service >/dev/null 2>&1 || true' \
      >/dev/null 2>&1 || true
  fi
  rm -f -- "$known_hosts"
}
trap cleanup EXIT HUP INT TERM

ssh_args=(
  -i "$BFU_SSH_KEY"
  -p "$ssh_port"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=5
  -o ConnectionAttempts=1
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)

# Intentional literal script: all substitutions and awk fields expand remotely.
# shellcheck disable=SC2016
health_command='set -eu
[ "$(cat /proc/1/comm)" = systemd ]
[ "$(systemctl is-system-running)" = running ]
[ "$(systemctl is-active dbus.service)" = active ]
[ "$(systemctl is-active ssh.service)" = active ]
[ "$(systemctl is-active dawnshell-boot-proof.service)" = active ]
[ -f /run/dawnshell-enabled-service.ready ]
[ "$(systemctl get-default)" = multi-user.target ]
[ "$(systemctl is-active multi-user.target)" = active ]
busctl --system --no-pager list >/dev/null
ss -H -ltn | awk '\''$4 ~ /:22$/ { found=1 } END { exit !found }'\''
if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
  cgroup_mode=v2
  cgroup_path="$(awk -F: '\''$1 == "0" && $2 == "" { print $3 }'\'' /proc/self/cgroup)"
  [ "$cgroup_path" = / ]
  [ -w /sys/fs/cgroup/cgroup.procs ]
  devices_hierarchy=0
else
  cgroup_mode=v1
  devices_hierarchy="$(awk '\''$1 == "devices" { print $2 }'\'' /proc/cgroups)"
  [ "${devices_hierarchy:-0}" -gt 0 ]
  [ -r /sys/fs/cgroup/devices/devices.list ]
  cgroup_path="$(awk -F: '\''$2 == "devices" { print $3 }'\'' /proc/self/cgroup)"
  [ "$cgroup_path" = / ]
fi
printf "pid1=%s start_ticks=%s machine_id=%s android_boot_id=%s system_state=%s dbus_state=%s ssh_state=%s proof_state=%s proof_marker=present target=%s target_state=%s cgroup_mode=%s cgroup_delegation=delegated devices_hierarchy=%s cgroup_path=%s\n" \
  "$(cat /proc/1/comm)" \
  "$(awk '\''{print $22}'\'' /proc/1/stat)" \
  "$(cat /etc/machine-id)" \
  "$(cat /proc/sys/kernel/random/boot_id)" \
  "$(systemctl is-system-running 2>/dev/null || true)" \
  "$(systemctl is-active dbus.service)" \
  "$(systemctl is-active ssh.service)" \
  "$(systemctl is-active dawnshell-boot-proof.service)" \
  "$(systemctl get-default)" \
  "$(systemctl is-active multi-user.target)" \
  "$cgroup_mode" \
  "$devices_hierarchy" \
  "$cgroup_path"'

adb get-state >/dev/null
operation_before="$( (read_boot_de_file "$operation_log_path" || true) \
  | wc -l | tr -d ' ' )"
locked_boot_before="$( (read_boot_de_file "$locked_boot_log_path" || true) \
  | wc -l | tr -d ' ' )"
root_before="$( (read_boot_de_file "$root_log_path" || true) \
  | wc -l | tr -d ' ' )"
rootfs_before="$( (read_boot_de_file "$rootfs_log_path" || true) \
  | wc -l | tr -d ' ' )"
runtime_before="$( (read_boot_de_file "$runtime_log_path" || true) \
  | wc -l | tr -d ' ' )"
lifecycle_before="$( (read_boot_de_file "$lifecycle_log_path" || true) \
  | wc -l | tr -d ' ' )"
ce_isolation_before="$( (read_boot_de_file "$ce_isolation_log_path" || true) \
  | wc -l | tr -d ' ' )"

adb logcat -c || true
pre_reboot_boot_id="$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r\n')"
[[ -n "$pre_reboot_boot_id" ]]
adb reboot

echo "Do not unlock the device. Waiting up to ${wait_seconds}s for BFU SSH..."
deadline=$((SECONDS + wait_seconds))
locked_health=""
while (( SECONDS < deadline )); do
  # The fixed command is intentionally passed as one SSH remote-command argument.
  # shellcheck disable=SC2029
  if locked_health="$(ssh "${ssh_args[@]}" \
      "$ssh_user@$BFU_PHONE_HOST" "$health_command" 2>/dev/null)"; then
    locked_android_boot_id="$(printf '%s\n' "$locked_health" \
      | sed -n 's/.*android_boot_id=\([^ ]*\).*/\1/p')"
    if [[ -n "$locked_android_boot_id" \
        && "$locked_android_boot_id" != "$pre_reboot_boot_id" ]]; then
      break
    fi
    locked_health=""
  fi
  sleep 3
done

[[ -n "$locked_health" ]] || {
  echo "FAIL: BFU SSH/systemd health did not pass before timeout" >&2
  exit 3
}

printf 'BFU health: %s\n' "$locked_health"
locked_identity="$(printf '%s\n' "$locked_health" \
  | sed -n 's/.*start_ticks=\([^ ]*\).*machine_id=\([^ ]*\).*/\1:\2/p')"
[[ -n "$locked_identity" ]]

echo "PASS: SSH :${ssh_port}, systemd PID 1, D-Bus, and ssh.service were live before unlock."

codec_command='set -eu
[ -x /usr/local/bin/dawnshell-codec ]
[ -x /usr/local/bin/dawnshell-codec-self-test ]
dawnshell-codec health --format json
dawnshell-codec capabilities
timeout 120 /usr/local/bin/dawnshell-codec-self-test'
if [[ "${BFU_REQUIRE_CODEC_PERFORMANCE:-0}" == "1" ]]; then
  codec_command+=$'\n[ -x /usr/local/bin/dawnshell-codec-performance-test ]\ntimeout 600 /usr/local/bin/dawnshell-codec-performance-test'
fi
if [[ "${BFU_REQUIRE_HARDWARE_CODEC:-0}" == "1" ]]; then
  echo "Running BFU hardware decode, encode, and Surface transcode self-test..."
  # Fixed command is intentionally executed by the remote Debian shell.
  # shellcheck disable=SC2029
  locked_codec_result="$(ssh "${ssh_args[@]}" \
    "$ssh_user@$BFU_PHONE_HOST" "$codec_command")"
  printf 'BFU codec result:\n%s\n' "$locked_codec_result"
  grep -Fq '"broker_state":"listening"' <<<"$locked_codec_result"
  grep -Fq '"user_unlocked":false' <<<"$locked_codec_result"
  grep -Fq 'hardware AVC decode passed' <<<"$locked_codec_result"
  grep -Fq 'hardware AVC encode passed' <<<"$locked_codec_result"
  grep -Fq 'Surface zero-copy AVC transcode passed' <<<"$locked_codec_result"
  if [[ "${BFU_REQUIRE_CODEC_PERFORMANCE:-0}" == "1" ]]; then
    grep -Fq 'hardware codec performance test passed' <<<"$locked_codec_result"
    grep -Fq 'decode_transport_comparison=verified' <<<"$locked_codec_result"
    grep -Fq 'codec_resource_cleanup=verified' <<<"$locked_codec_result"
    grep -Fq 'codec_error_isolation=verified' <<<"$locked_codec_result"
    grep -Fq 'codec concurrency test passed' <<<"$locked_codec_result"
    grep -Fq 'codec_cpu_baseline=recorded' <<<"$locked_codec_result"
    grep -Fq 'codec_quality=verified' <<<"$locked_codec_result"
  fi
  locked_codec_pid="$(sed -n \
    's/.*"broker_state":"listening","pid":\([0-9][0-9]*\).*/\1/p' \
    <<<"$locked_codec_result" | head -n 1)"
  [[ -n "$locked_codec_pid" ]]

  echo "Keeping one hardware decoder session open across USER_UNLOCKED..."
  # Fixed command is intentionally executed by the remote Debian shell.
  # shellcheck disable=SC2029
  locked_hold_health="$(ssh "${ssh_args[@]}" "$ssh_user@$BFU_PHONE_HOST" \
    'set -eu
systemctl stop dawnshell-codec-unlock-hold.service >/dev/null 2>&1 || true
systemctl reset-failed dawnshell-codec-unlock-hold.service >/dev/null 2>&1 || true
systemd-run --quiet --collect --unit=dawnshell-codec-unlock-hold.service \
  /usr/local/bin/dawnshell-codec hold-test decode 240000
for attempt in $(seq 1 20); do
  health="$(dawnshell-codec health --format json)"
  case "$health" in
    *"\"active_sessions\":1"*) printf "%s\n" "$health"; exit 0 ;;
  esac
  sleep 1
done
journalctl --no-pager -n 40 -u dawnshell-codec-unlock-hold.service >&2
exit 1')"
  grep -Fq '"active_sessions":1' <<<"$locked_hold_health"
  grep -Fq '"user_unlocked":false' <<<"$locked_hold_health"
  codec_hold_started=1
fi

if [[ "${BFU_SKIP_UNLOCK_CONTINUITY:-}" == "1" ]]; then
  exit 0
fi

if [[ -t 0 ]]; then
  read -r -p "Unlock Android once, wait for the home screen, then press Enter... "
else
  echo "Unlock Android once. Waiting for ADB and RUNNING_UNLOCKED..."
  adb wait-for-device
  unlock_deadline=$((SECONDS + 180))
  while (( SECONDS < unlock_deadline )); do
    if adb shell dumpsys user 2>/dev/null \
        | tr -d '\r' | grep -Fq 'State: RUNNING_UNLOCKED'; then
      break
    fi
    sleep 1
  done
  adb shell dumpsys user 2>/dev/null \
    | tr -d '\r' | grep -Fq 'State: RUNNING_UNLOCKED' || {
      echo "FAIL: Android did not reach RUNNING_UNLOCKED within 180s" >&2
      exit 4
    }
fi
# shellcheck disable=SC2029
unlocked_health="$(ssh "${ssh_args[@]}" \
  "$ssh_user@$BFU_PHONE_HOST" "$health_command")"
printf 'AFU health: %s\n' "$unlocked_health"
unlocked_identity="$(printf '%s\n' "$unlocked_health" \
  | sed -n 's/.*start_ticks=\([^ ]*\).*machine_id=\([^ ]*\).*/\1:\2/p')"

if [[ "${BFU_REQUIRE_HARDWARE_CODEC:-0}" == "1" ]]; then
  # Prove that the same broker and an already-open hardware session survived
  # USER_UNLOCKED before running any new AFU sessions.
  # shellcheck disable=SC2029
  unlocked_hold_health="$(ssh "${ssh_args[@]}" "$ssh_user@$BFU_PHONE_HOST" \
    'set -eu
[ "$(systemctl is-active dawnshell-codec-unlock-hold.service)" = active ]
dawnshell-codec health --format json')"
  printf 'AFU in-flight codec health:\n%s\n' "$unlocked_hold_health"
  grep -Fq '"active_sessions":1' <<<"$unlocked_hold_health"
  grep -Fq '"user_unlocked":true' <<<"$unlocked_hold_health"
  unlocked_codec_pid="$(sed -n \
    's/.*"broker_state":"listening","pid":\([0-9][0-9]*\).*/\1/p' \
    <<<"$unlocked_hold_health" | head -n 1)"
  [[ "$unlocked_codec_pid" = "$locked_codec_pid" ]] || {
    echo "FAIL: hardware codec broker PID changed across USER_UNLOCKED" >&2
    exit 4
  }
  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" "$ssh_user@$BFU_PHONE_HOST" \
    'set -eu
systemctl stop dawnshell-codec-unlock-hold.service
for attempt in $(seq 1 20); do
  health="$(dawnshell-codec health --format json)"
  case "$health" in
    *"\"active_sessions\":0"*"\"active_transcoders\":0"*) \
      printf "%s\n" "$health"; exit 0 ;;
  esac
  sleep 1
done
exit 1'
  codec_hold_started=0
  echo "Re-running hardware codec self-test after USER_UNLOCKED..."
  # shellcheck disable=SC2029
  unlocked_codec_result="$(ssh "${ssh_args[@]}" \
    "$ssh_user@$BFU_PHONE_HOST" "$codec_command")"
  printf 'AFU codec result:\n%s\n' "$unlocked_codec_result"
  grep -Fq '"broker_state":"listening"' <<<"$unlocked_codec_result"
  grep -Fq '"user_unlocked":true' <<<"$unlocked_codec_result"
  grep -Fq 'Surface zero-copy AVC transcode passed' <<<"$unlocked_codec_result"
  if [[ "${BFU_REQUIRE_CODEC_PERFORMANCE:-0}" == "1" ]]; then
    grep -Fq 'hardware codec performance test passed' <<<"$unlocked_codec_result"
    grep -Fq 'realtime=true' <<<"$unlocked_codec_result"
    grep -Fq 'codec_error_isolation=verified' <<<"$unlocked_codec_result"
    grep -Fq 'codec concurrency test passed' <<<"$unlocked_codec_result"
    grep -Fq 'codec_cpu_baseline=recorded' <<<"$unlocked_codec_result"
    grep -Fq 'codec_quality=verified' <<<"$unlocked_codec_result"
  fi
fi

[[ "$unlocked_identity" = "$locked_identity" ]] || {
  echo "FAIL: Debian PID 1 identity changed across USER_UNLOCKED" >&2
  exit 4
}

adb wait-for-device
adb logcat -d -s DawnShell:I '*:S' || true

lifecycle_status="$(read_boot_de_file "$lifecycle_status_path")"
printf 'Persisted lifecycle status: %s\n' "$lifecycle_status"
grep -Fq 'trigger=locked_boot' <<<"$lifecycle_status"
grep -Fq 'user_unlocked_before=false' <<<"$lifecycle_status"
grep -Fq 'user_unlocked_after=false' <<<"$lifecycle_status"
grep -Fq 'health_exit=0' <<<"$lifecycle_status"
grep -Fq 'system_state=running' <<<"$lifecycle_status"
grep -Fq 'dbus_bus=ok' <<<"$lifecycle_status"
grep -Fq 'boot_proof_service=active' <<<"$lifecycle_status"
grep -Fq 'boot_proof_marker=present' <<<"$lifecycle_status"
grep -Fq 'target_state=active' <<<"$lifecycle_status"
grep -Fq 'listen_22=true' <<<"$lifecycle_status"
grep -Fq 'cgroup_delegation=delegated' <<<"$lifecycle_status"

locked_boot_new="$(fresh_log_lines "$locked_boot_log_path" "$locked_boot_before")"
printf '%s\n' "$locked_boot_new"
require_one_fresh_record "LOCKED_BOOT_COMPLETED" \
  'LOCKED_BOOT_COMPLETED ' "$locked_boot_new"

root_new="$(fresh_log_lines "$root_log_path" "$root_before")"
printf '%s\n' "$root_new"
require_one_fresh_record "BFU root probe" 'ROOT_PROBE ' "$root_new"
grep -Fq 'exit=0 timeout=false root=true' <<<"$root_new"
grep -Fq 'user_unlocked_before=false user_unlocked_after=false' <<<"$root_new"
grep -Fq 'output=uid=0(' <<<"$root_new"

rootfs_new="$(fresh_log_lines "$rootfs_log_path" "$rootfs_before")"
printf '%s\n' "$rootfs_new"
require_one_fresh_record "BFU rootfs probe" 'ROOTFS_PROBE ' "$rootfs_new"
grep -Fq 'rootfs=/data/local/debian' <<<"$rootfs_new"
grep -Fq 'exit=0 timeout=false accessible=true' <<<"$rootfs_new"
grep -Fq 'user_unlocked_before=false user_unlocked_after=false' <<<"$rootfs_new"
grep -Fq 'Debian-rootfs-access-ok root=/data/local/debian' <<<"$rootfs_new"

runtime_new="$(fresh_log_lines "$runtime_log_path" "$runtime_before")"
printf '%s\n' "$runtime_new"
require_one_fresh_record "BFU namespace/chroot probe" \
  'DEBIAN_RUNTIME_PROBE ' "$runtime_new"
grep -Fq 'exit=0 timeout=false namespace_chroot=true' <<<"$runtime_new"
grep -Fq 'user_unlocked_before=false user_unlocked_after=false' <<<"$runtime_new"
grep -Fq "BFU_DEBIAN_NAMESPACE_OK pid=1 proc1=sh arch=$debian_arch debian=13" \
  <<<"$runtime_new"
grep -Fq 'init=present systemctl=present' <<<"$runtime_new"

operation_all="$(read_boot_de_file "$operation_log_path")"
operation_new="$(printf '%s\n' "$operation_all" \
  | sed -n "$((operation_before + 1)),\$p")"
printf '%s\n' "$operation_new"
grep -Fq 'USER_UNLOCKED received; Debian lifecycle unchanged' <<<"$operation_new"

lifecycle_all="$(read_boot_de_file "$lifecycle_log_path")"
lifecycle_new="$(printf '%s\n' "$lifecycle_all" \
  | sed -n "$((lifecycle_before + 1)),\$p")"
printf '%s\n' "$lifecycle_new"
grep -Fq 'BFU_DEBIAN_SYSTEMD_STARTED' <<<"$lifecycle_new"
grep -Fq 'label=host_proc_cgroups' <<<"$lifecycle_new"
grep -Fq 'label=host_cgroup_v2_controllers' <<<"$lifecycle_new"
if grep -Fq 'cgroup_mode=v2' <<<"$locked_health"; then
  grep -Fq 'cgroup_v2_device_bpf_verified' <<<"$lifecycle_new"
  grep -Fq 'cgroup_resolved=v2' <<<"$lifecycle_new"
  grep -Fq 'init_moved_to_cgroup_v2_payload' <<<"$lifecycle_new"
  grep -Fq 'private_cgroup_views_mounted mode=v2 delegated_subtree=true' \
    <<<"$lifecycle_new"
else
  grep -Fq 'cgroup_v1_devices_mounted' <<<"$lifecycle_new"
  grep -Fq 'label=delegated_devices_list' <<<"$lifecycle_new"
  grep -Fq 'cgroup_v1_name_systemd_mounted' <<<"$lifecycle_new"
  grep -Fq 'init_moved_to_devices_cgroup' <<<"$lifecycle_new"
  grep -Fq 'private_cgroup_views_mounted mode=v1 delegated_subtree=true' \
    <<<"$lifecycle_new"
fi
grep -Fq 'label=debian_pid1_cgroup' <<<"$lifecycle_new"
grep -Fq 'ipc_namespace=android-shared' <<<"$lifecycle_new"
grep -Fq 'network_namespace=android-shared network_mode=shared-nic' <<<"$lifecycle_new"
grep -Fq 'ANDROID_HEALTH attempt=' <<<"$lifecycle_new"
grep -Fq 'ready=true' <<<"$lifecycle_new"

ce_isolation_all="$(read_boot_de_file "$ce_isolation_log_path")"
ce_isolation_new="$(printf '%s\n' "$ce_isolation_all" \
  | sed -n "$((ce_isolation_before + 1)),\$p")"
printf '%s\n' "$ce_isolation_new"
require_one_fresh_record "BFU CE isolation probe" \
  'CE_ISOLATION_PROBE ' "$ce_isolation_new"
grep -Fq 'user_unlocked_before=false' <<<"$ce_isolation_new"
grep -Fq 'user_unlocked_after=false' <<<"$ce_isolation_new"
if [[ "$expect_ce_override" == "1" ]]; then
  grep -Fq 'ce_isolated=false' <<<"$ce_isolation_new"
  grep -Fq 'exit=41 timeout=false' <<<"$ce_isolation_new"
  grep -Fq 'BFU_APP_CE_CONTENT_ACCESSIBLE' <<<"$ce_isolation_new"
  grep -Fq 'CE_ISOLATION_OVERRIDE_USED' <<<"$operation_new"
else
  grep -Fq 'ce_isolated=true' <<<"$ce_isolation_new"
  grep -Fq 'BFU_APP_CE_ISOLATED sentinel_unreadable=true' <<<"$ce_isolation_new"
fi

echo "PASS: USER_UNLOCKED preserved the same Debian systemd instance."
