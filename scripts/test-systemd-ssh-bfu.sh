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
[ "$(systemctl get-default)" = multi-user.target ]
busctl --system --no-pager list >/dev/null
ss -H -ltn | awk '\''$4 ~ /:22$/ { found=1 } END { exit !found }'\''
printf "pid1=%s start_ticks=%s machine_id=%s system_state=%s dbus_state=%s ssh_state=%s target=%s\n" \
  "$(cat /proc/1/comm)" \
  "$(awk '\''{print $22}'\'' /proc/1/stat)" \
  "$(cat /etc/machine-id)" \
  "$(systemctl is-system-running 2>/dev/null || true)" \
  "$(systemctl is-active dbus.service)" \
  "$(systemctl is-active ssh.service)" \
  "$(systemctl get-default)"'

adb get-state >/dev/null
operation_before="$( (read_boot_de_file "$operation_log_path" || true) \
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
grep -Fq 'listen_22=true' <<<"$lifecycle_status"

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
grep -Fq 'network_namespace=android-shared' <<<"$lifecycle_new"
grep -Fq 'ANDROID_HEALTH attempt=' <<<"$lifecycle_new"
grep -Fq 'ready=true' <<<"$lifecycle_new"

ce_isolation_all="$(read_boot_de_file "$ce_isolation_log_path")"
ce_isolation_new="$(printf '%s\n' "$ce_isolation_all" \
  | sed -n "$((ce_isolation_before + 1)),\$p")"
printf '%s\n' "$ce_isolation_new"
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
