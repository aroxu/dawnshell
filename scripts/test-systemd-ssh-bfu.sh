#!/usr/bin/env bash
set -euo pipefail

: "${BFU_PHONE_HOST:?Set BFU_PHONE_HOST to the phone IP address reachable before unlock}"
: "${BFU_SSH_KEY:?Set BFU_SSH_KEY to the local private key matching the configured public key}"

ssh_user="${BFU_SSH_USER:-debian}"
ssh_port="${BFU_SSH_PORT:-22}"
wait_seconds="${BFU_SSH_WAIT_SECONDS:-180}"

[[ -f "$BFU_SSH_KEY" ]] || {
  echo "Private key does not exist: $BFU_SSH_KEY" >&2
  exit 2
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

health_command='set -eu
[ "$(cat /proc/1/comm)" = systemd ]
[ "$(systemctl is-active ssh.service)" = active ]
ss -H -ltn | awk '\''$4 ~ /:22$/ { found=1 } END { exit !found }'\''
printf "pid1=%s start_ticks=%s machine_id=%s system_state=%s ssh_state=%s\n" \
  "$(cat /proc/1/comm)" \
  "$(awk '\''{print $22}'\'' /proc/1/stat)" \
  "$(cat /etc/machine-id)" \
  "$(systemctl is-system-running 2>/dev/null || true)" \
  "$(systemctl is-active ssh.service)"'

adb logcat -c || true
adb reboot

echo "Do not unlock the device. Waiting up to ${wait_seconds}s for BFU SSH..."
deadline=$((SECONDS + wait_seconds))
locked_health=""
while (( SECONDS < deadline )); do
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

echo "PASS: SSH :${ssh_port}, systemd PID 1, and ssh.service were live before unlock."

if [[ "${BFU_SKIP_UNLOCK_CONTINUITY:-}" == "1" ]]; then
  exit 0
fi

read -r -p "Unlock Android once, wait for the home screen, then press Enter... "
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
adb shell run-as com.termux.boot cat \
  /data/user_de/0/com.termux.boot/files/bfu/run/debian-lifecycle.log || true

echo "PASS: USER_UNLOCKED preserved the same Debian systemd instance."
