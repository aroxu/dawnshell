#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_script="$repo_dir/app/src/main/assets/bfu/configure-host-usb.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT

sed -n '/^#!\/bin\/bash$/,/^EOF_LSUSB$/p' "$policy_script" \
    | sed '$d; s#^real_lsusb=/usr/bin/lsusb$#real_lsusb="${DAWNSHELL_FAKE_LSUSB:?}"#' \
    > "$temporary_dir/lsusb"
chmod +x "$temporary_dir/lsusb"

cat > "$temporary_dir/fake-lsusb" <<'EOF_FAKE_LSUSB'
#!/usr/bin/env bash
echo "unable to initialize usb spec" >&2
echo "/sys/bus/usb/devices/1-1/rx_lanes: No such file or directory" >&2
echo "/sys/bus/usb/devices/1-1/tx_lanes: No such file or directory" >&2
echo "real USB diagnostic" >&2
printf '/: Bus 001.Port 001: Dev 001, Driver=xhci-hcd\n'
EOF_FAKE_LSUSB
chmod +x "$temporary_dir/fake-lsusb"

DAWNSHELL_FAKE_LSUSB="$temporary_dir/fake-lsusb" \
    "$temporary_dir/lsusb" -t \
    > "$temporary_dir/stdout" 2> "$temporary_dir/stderr"

grep -Fqx '/: Bus 001.Port 001: Dev 001, Driver=xhci-hcd' "$temporary_dir/stdout"
grep -Fqx 'real USB diagnostic' "$temporary_dir/stderr"
if grep -Eq 'rx_lanes|tx_lanes|unable to initialize usb spec' "$temporary_dir/stderr"; then
    echo "Legacy sysfs warning was not filtered from lsusb stderr" >&2
    cat "$temporary_dir/stderr" >&2
    exit 1
fi

echo "Host USB legacy-sysfs lsusb filter tests passed"
