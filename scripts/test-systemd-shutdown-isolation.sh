#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac

: "${BFU_PHONE_HOST:?Set BFU_PHONE_HOST to the phone IP address}"
: "${BFU_SSH_KEY:?Set BFU_SSH_KEY to the dedicated BFU SSH private key}"

ssh_user="${BFU_SSH_USER:-debian}"
ssh_port="${BFU_SSH_PORT:-22}"
wait_seconds="${BFU_SSH_WAIT_SECONDS:-120}"
helper="/data/user_de/0/me.aroxu.dawnshell/files/bfu/bin/bfu-namespace-probe-arm64"
rootfs="/data/local/debian"
control="/data/user_de/0/me.aroxu.dawnshell/files/bfu/run"
lifecycle_log="$control/debian-lifecycle.log"

[[ -f "$BFU_SSH_KEY" ]] || {
  echo "Private key does not exist: $BFU_SSH_KEY" >&2
  exit 2
}

for tool in adb ssh timeout; do
  command -v "$tool" >/dev/null || {
    echo "Missing host tool: $tool" >&2
    exit 2
  }
done

known_hosts="$(mktemp)"
cleanup() {
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
printf "pid1_start_ticks=%s machine_id=%s proof_state=%s proof_marker=present target_state=%s\n" \
  "$(awk '\''{print $22}'\'' /proc/1/stat)" "$(cat /etc/machine-id)" \
  "$(systemctl is-active dawnshell-boot-proof.service)" \
  "$(systemctl is-active multi-user.target)"'

wait_for_ssh() {
  local deadline=$((SECONDS + wait_seconds))
  local output=""
  while (( SECONDS < deadline )); do
    # The fixed command is intentionally passed as one SSH remote-command argument.
    # shellcheck disable=SC2029
    if output="$(ssh "${ssh_args[@]}" \
        "$ssh_user@$BFU_PHONE_HOST" "$health_command" 2>/dev/null)"; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 2
  done
  return 1
}

android_boot_id() {
  adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r\n'
}

start_debian() {
  local command="$helper start $rootfs $control $lifecycle_log"
  timeout 45 adb shell su -c "$command"
  wait_for_ssh >/dev/null || {
    echo "FAIL: Debian SSH health did not recover after start" >&2
    exit 6
  }
}

adb get-state >/dev/null
root_result="$(adb shell su -c id | tr -d '\r')"
[[ "$root_result" == uid=0* ]] || {
  echo "FAIL: adb shell su is not pre-authorized: $root_result" >&2
  exit 3
}

initial_health="$(wait_for_ssh)" || {
  echo "FAIL: Debian is not healthy before shutdown isolation tests" >&2
  exit 3
}
printf 'Initial Debian health: %s\n' "$initial_health"

initial_boot_id="$(android_boot_id)"
status_output="$(timeout 20 adb shell su -c \
  "$helper status $rootfs $control" | tr -d '\r')"
printf '%s\n' "$status_output"
grep -Fq 'BFU_DEBIAN_RUNNING' <<<"$status_output"
grep -Fq 'supervisor_identity_valid=true' <<<"$status_output"
grep -Fq 'init_identity_valid=true' <<<"$status_output"
grep -Fq 'namespace_topology_valid=true' <<<"$status_output"
grep -Fq 'ipc_namespace=android-shared' <<<"$status_output"
grep -Fq 'network_namespace=android-shared network_mode=shared-nic' <<<"$status_output"

echo "Testing explicit restart-debian helper..."
restart_output="$(timeout 80 adb shell su -c \
  "$helper restart $rootfs $control $lifecycle_log" | tr -d '\r')"
printf '%s\n' "$restart_output"
restarted_health="$(wait_for_ssh)" || {
  echo "FAIL: Debian did not become healthy after explicit restart" >&2
  exit 6
}
[[ "$restarted_health" != "$initial_health" ]] || {
  echo "FAIL: Debian PID 1 identity did not change after explicit restart" >&2
  exit 6
}
[[ "$(android_boot_id)" = "$initial_boot_id" ]] || {
  echo "FAIL: explicit Debian restart changed the Android boot ID" >&2
  exit 4
}
echo "PASS: restart-debian replaced Debian PID 1 without rebooting Android."

echo "Testing explicit graceful stop-debian helper..."
stop_output="$(timeout 45 adb shell su -c \
  "$helper stop $rootfs $control" | tr -d '\r')"
printf '%s\n' "$stop_output"
grep -Fq 'BFU_DEBIAN_STOPPED' <<<"$stop_output"
stopped_status="$(timeout 20 adb shell su -c \
  "$helper status $rootfs $control" | tr -d '\r')"
printf '%s\n' "$stopped_status"
grep -Fq 'last_state=stopped' <<<"$stopped_status"
grep -Fq 'wait_status=0' <<<"$stopped_status"
grep -Fq 'systemd_manager_exit_queued' \
  < <(adb exec-out run-as me.aroxu.dawnshell cat "$lifecycle_log" 2>/dev/null \
      | tr -d '\r')
if ssh "${ssh_args[@]}" "$ssh_user@$BFU_PHONE_HOST" true 2>/dev/null; then
  echo "FAIL: SSH still accepted a session after stop-debian completed" >&2
  exit 6
fi
[[ "$(android_boot_id)" = "$initial_boot_id" ]] || {
  echo "FAIL: graceful Debian stop changed the Android boot ID" >&2
  exit 4
}
start_debian
echo "PASS: stop-debian halted only the Debian namespace and start-debian restored it."

for mode in poweroff reboot shutdown; do
  before_boot_id="$(android_boot_id)"
  [[ -n "$before_boot_id" ]]
  if [[ "$mode" == shutdown ]]; then
    echo "Testing /usr/sbin/shutdown inside the Debian PID namespace..."
  else
    echo "Testing systemctl $mode inside the Debian PID namespace..."
  fi

  command="$helper shutdown-test $rootfs $control $mode"
  set +e
  output="$(timeout 75 adb shell su -c "$command" 2>&1)"
  result=$?
  set -e
  printf '%s\n' "$output"

  if (( result != 0 )); then
    if timeout 60 adb wait-for-device >/dev/null 2>&1; then
      after_failure_boot_id="$(android_boot_id)"
      if [[ "$after_failure_boot_id" != "$before_boot_id" ]]; then
        echo "FAIL: Debian systemctl $mode rebooted Android itself" >&2
        exit 4
      fi
    fi
    echo "FAIL: Debian shutdown-test $mode exited with status $result" >&2
    exit 5
  fi

  grep -Fq "BFU_DEBIAN_SHUTDOWN_TEST_COMPLETED mode=$mode" <<<"$output" || {
    echo "FAIL: helper did not prove the Debian supervisor stopped" >&2
    exit 5
  }
  adb get-state >/dev/null
  after_boot_id="$(android_boot_id)"
  [[ "$after_boot_id" = "$before_boot_id" ]] || {
    echo "FAIL: Android boot ID changed during Debian systemctl $mode" >&2
    exit 4
  }

  start_debian
  restarted_boot_id="$(android_boot_id)"
  [[ "$restarted_boot_id" = "$before_boot_id" ]] || {
    echo "FAIL: Android rebooted while restoring Debian after $mode" >&2
    exit 4
  }
  echo "PASS: $mode stopped only Debian; Android stayed on boot $before_boot_id."
done

echo "PASS: Debian poweroff/reboot/shutdown paths are isolated from Android host lifecycle."
