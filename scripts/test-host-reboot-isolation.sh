#!/usr/bin/env bash
# Pins the two reboot paths apart:
#   1. A deliberate `reboot now` inside Debian must still restart Android.
#   2. A container runtime must not be able to restart Android by calling
#      reboot(2) directly, because this kernel does not confine that call to
#      the private PID namespace.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
test -f "$launcher"
test -f "$configurator"

# Debian and every container it starts must lose CAP_SYS_BOOT.
grep -Fq 'prctl(PR_CAPBSET_DROP, CAP_SYS_BOOT, 0, 0, 0)' "$launcher"
grep -Fq 'cap_sys_boot_dropped' "$launcher"

# The drop must happen in the shared namespace setup so that both the probe
# and the systemd launch path inherit it.
python3 - "$launcher" <<'PYTHON_VERIFY_CAPABILITY_DROP'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("static int set_base_private_namespaces(void) {")
end = source.index("\n}\n", start)
body = source[start:end]
if "PR_CAPBSET_DROP" not in body:
    raise SystemExit("CAP_SYS_BOOT must be dropped in set_base_private_namespaces")
if body.index("PR_CAPBSET_DROP") > body.index("unshare(CLONE_NEWNS)"):
    raise SystemExit("CAP_SYS_BOOT must be dropped before entering namespaces")

# The Android-side reboot bridge must fork before that drop, so a deliberate
# reboot still works.
manager = source.index("start_network_manager(getpid()")
namespaces = source.index("set_systemd_parent_namespaces(control_dir")
if manager > namespaces:
    raise SystemExit("the reboot bridge must start before capabilities drop")
print("reboot bridge starts before CAP_SYS_BOOT is dropped")
PYTHON_VERIFY_CAPABILITY_DROP

# The supervisor-side bridge keeps the privileged reboot path.
grep -Fq 'ANDROID_REBOOT' "$launcher"
grep -Fq '"/system/bin/reboot"' "$launcher"
grep -Fq 'BFU_DEBIAN_HOST_REBOOT_REQUEST' "$launcher"

# Debian's user-facing command must ask the bridge instead of the kernel.
# shellcheck disable=SC2016 # Assert literal generated shell source.
grep -Fq 'printf '"'"'ANDROID_REBOOT\n'"'"' > "$bridge"' "$configurator"
grep -Fq '/usr/local/sbin/reboot' "$configurator"

echo "PASS: deliberate reboot still restarts Android; container reboot(2) is blocked."
