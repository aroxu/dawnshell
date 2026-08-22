#!/usr/bin/env bash
set -euo pipefail

: "${BFU_PHONE_HOST:?Set BFU_PHONE_HOST to the phone IP address reachable before unlock}"
: "${BFU_SSH_KEY:?Set BFU_SSH_KEY to the local private key matching the configured public key}"

ssh_user="${BFU_SSH_USER:-debian}"
ssh_port="${BFU_SSH_PORT:-22}"
wait_seconds="${BFU_SSH_WAIT_SECONDS:-180}"
verify_handoff="${BFU_VERIFY_AFU_HANDOFF:-1}"
if [[ "${BFU_SKIP_UNLOCK_CONTINUITY:-}" == "1" ]]; then
  verify_handoff=0
fi
operation_log_path="/data/user_de/0/com.termux.boot/files/bfu-operation.log"
locked_boot_log_path="/data/user_de/0/com.termux.boot/files/bfu-boot.log"
root_log_path="/data/user_de/0/com.termux.boot/files/bfu-root.log"
rootfs_log_path="/data/user_de/0/com.termux.boot/files/bfu-rootfs.log"
runtime_log_path="/data/user_de/0/com.termux.boot/files/bfu-debian-runtime.log"
lifecycle_status_path="/data/user_de/0/com.termux.boot/files/debian-lifecycle.status"
lifecycle_log_path="/data/user_de/0/com.termux.boot/files/bfu/run/debian-lifecycle.log"
ce_isolation_log_path="/data/user_de/0/com.termux.boot/files/bfu-ce-isolation.log"
handoff_script="/data/data/com.termux/files/home/.termux/boot/00-termux-bfu-handoff-test"
handoff_marker="/data/data/com.termux/files/home/.termux/bfu-handoff-test.marker"

[[ -f "$BFU_SSH_KEY" ]] || {
  echo "Private key does not exist: $BFU_SSH_KEY" >&2
  exit 2
}

for tool in adb ssh sed; do
  command -v "$tool" >/dev/null || {
    echo "Missing host tool: $tool" >&2
    exit 2
  }
done

read_boot_de_file() {
  adb exec-out run-as com.termux.boot cat "$1" 2>/dev/null | tr -d '\r'
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
cleanup() {
  rm -f -- "$known_hosts"
}
trap cleanup EXIT HUP INT TERM

ssh_args=(
  -i "$BFU_SSH_KEY"
  -p "$ssh_port"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ConnectionAttempts=1
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)

# Intentional literal script: all substitutions and awk fields expand remotely.
# shellcheck disable=SC2016
health_command='set -eu
[ "$(cat /proc/1/comm)" = systemd ]
[ "$(systemctl is-active dbus.service)" = active ]
[ "$(systemctl is-active ssh.service)" = active ]
[ "$(systemctl is-active termux-bfu-boot-proof.service)" = active ]
[ -f /run/termux-bfu-enabled-service.ready ]
[ "$(systemctl get-default)" = multi-user.target ]
busctl --system --no-pager list >/dev/null
ss -H -ltn | awk '\''$4 ~ /:22$/ { found=1 } END { exit !found }'\''
printf "pid1=%s start_ticks=%s machine_id=%s system_state=%s dbus_state=%s ssh_state=%s proof_state=%s proof_marker=present target=%s\n" \
  "$(cat /proc/1/comm)" \
  "$(awk '\''{print $22}'\'' /proc/1/stat)" \
  "$(cat /etc/machine-id)" \
  "$(systemctl is-system-running 2>/dev/null || true)" \
  "$(systemctl is-active dbus.service)" \
  "$(systemctl is-active ssh.service)" \
  "$(systemctl is-active termux-bfu-boot-proof.service)" \
  "$(systemctl get-default)"'

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

if [[ "$verify_handoff" == "1" ]]; then
  adb shell run-as com.termux mkdir -p \
    /data/data/com.termux/files/home/.termux/boot
  adb shell run-as com.termux rm -f "$handoff_marker"
  handoff_body="#!/data/data/com.termux/files/usr/bin/sh
/system/bin/cat /proc/sys/kernel/random/boot_id > $handoff_marker"
  printf '%s\n' "$handoff_body" \
    | adb shell "run-as com.termux sh -c 'cat > $handoff_script'"
  adb shell run-as com.termux chmod 0700 "$handoff_script"
fi

adb logcat -c || true
adb reboot

echo "Do not unlock the device. Waiting up to ${wait_seconds}s for BFU SSH..."
deadline=$((SECONDS + wait_seconds))
locked_health=""
while (( SECONDS < deadline )); do
  # The fixed command is intentionally passed as one SSH remote-command argument.
  # shellcheck disable=SC2029
  if locked_health="$(ssh "${ssh_args[@]}" \
      "$ssh_user@$BFU_PHONE_HOST" "$health_command" 2>/dev/null)"; then
    break
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

if [[ "${BFU_SKIP_UNLOCK_CONTINUITY:-}" == "1" ]]; then
  exit 0
fi

read -r -p "Unlock Android once, wait for the home screen, then press Enter... "
# shellcheck disable=SC2029
unlocked_health="$(ssh "${ssh_args[@]}" \
  "$ssh_user@$BFU_PHONE_HOST" "$health_command")"
printf 'AFU health: %s\n' "$unlocked_health"
unlocked_identity="$(printf '%s\n' "$unlocked_health" \
  | sed -n 's/.*start_ticks=\([^ ]*\).*machine_id=\([^ ]*\).*/\1:\2/p')"

[[ "$unlocked_identity" = "$locked_identity" ]] || {
  echo "FAIL: Debian PID 1 identity changed across USER_UNLOCKED" >&2
  exit 4
}

adb wait-for-device
adb logcat -d -s TermuxBFU:I '*:S' || true

lifecycle_status="$(read_boot_de_file "$lifecycle_status_path")"
printf 'Persisted lifecycle status: %s\n' "$lifecycle_status"
grep -Fq 'trigger=locked_boot' <<<"$lifecycle_status"
grep -Fq 'user_unlocked_before=false' <<<"$lifecycle_status"
grep -Fq 'user_unlocked_after=false' <<<"$lifecycle_status"
grep -Fq 'health_exit=0' <<<"$lifecycle_status"
grep -Fq 'dbus_bus=ok' <<<"$lifecycle_status"
grep -Fq 'boot_proof_service=active' <<<"$lifecycle_status"
grep -Fq 'boot_proof_marker=present' <<<"$lifecycle_status"
grep -Fq 'listen_22=true' <<<"$lifecycle_status"

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
grep -Fq 'BFU_DEBIAN_NAMESPACE_OK pid=1 proc1=sh arch=arm64 debian=13' \
  <<<"$runtime_new"
grep -Fq 'init=present systemctl=present' <<<"$runtime_new"

operation_all="$(read_boot_de_file "$operation_log_path")"
operation_new="$(printf '%s\n' "$operation_all" \
  | sed -n "$((operation_before + 1)),\$p")"
printf '%s\n' "$operation_new"
grep -Fq 'USER_UNLOCKED received; Debian lifecycle unchanged' <<<"$operation_new"
handoff_count="$(grep -Fc 'NORMAL_BOOT_HANDOFF_STARTED user_unlocked=true' \
  <<<"$operation_new" || true)"
[[ "$handoff_count" == "1" ]] || {
  echo "FAIL: expected one normal Termux handoff, observed $handoff_count" >&2
  exit 5
}

lifecycle_all="$(read_boot_de_file "$lifecycle_log_path")"
lifecycle_new="$(printf '%s\n' "$lifecycle_all" \
  | sed -n "$((lifecycle_before + 1)),\$p")"
printf '%s\n' "$lifecycle_new"
grep -Fq 'BFU_DEBIAN_SYSTEMD_STARTED' <<<"$lifecycle_new"
grep -Fq 'label=host_proc_cgroups' <<<"$lifecycle_new"
grep -Fq 'cgroup_v1_name_systemd_mounted' <<<"$lifecycle_new"
grep -Fq 'private_systemd_cgroup_view_mounted' <<<"$lifecycle_new"
grep -Fq 'label=debian_pid1_cgroup' <<<"$lifecycle_new"
grep -Fq 'network_namespace=android-shared' <<<"$lifecycle_new"
grep -Fq 'ANDROID_HEALTH attempt=' <<<"$lifecycle_new"
grep -Fq 'ready=true' <<<"$lifecycle_new"

ce_isolation_all="$(read_boot_de_file "$ce_isolation_log_path")"
ce_isolation_new="$(printf '%s\n' "$ce_isolation_all" \
  | sed -n "$((ce_isolation_before + 1)),\$p")"
printf '%s\n' "$ce_isolation_new"
require_one_fresh_record "BFU CE isolation probe" \
  'CE_ISOLATION_PROBE ' "$ce_isolation_new"
grep -Fq 'ce_isolated=true' <<<"$ce_isolation_new"
grep -Fq 'user_unlocked_before=false' <<<"$ce_isolation_new"
grep -Fq 'user_unlocked_after=false' <<<"$ce_isolation_new"
grep -Fq 'TERMUX_CE_ISOLATED paths_unreadable=true' <<<"$ce_isolation_new"

if [[ "$verify_handoff" == "1" ]]; then
  marker_deadline=$((SECONDS + 30))
  marker_boot_id=""
  while (( SECONDS < marker_deadline )); do
    marker_boot_id="$(adb exec-out run-as com.termux cat "$handoff_marker" \
      2>/dev/null | tr -d '\r\n' || true)"
    [[ -n "$marker_boot_id" ]] && break
    sleep 1
  done
  android_boot_id="$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r\n')"
  [[ "$marker_boot_id" = "$android_boot_id" ]] || {
    echo "FAIL: normal Termux:Boot test script did not run for this Android boot" >&2
    exit 6
  }
  adb shell run-as com.termux rm -f "$handoff_script" "$handoff_marker"
  echo "PASS: the normal Termux:Boot script executed exactly in the current boot."
fi

echo "PASS: USER_UNLOCKED preserved the same Debian systemd instance."
