#!/system/bin/sh
set -eu

ROOT=/data/local/debian

fail() {
    code="$1"
    shift
    echo "ERROR: $*"
    exit "$code"
}

[ "$#" -eq 2 ] || fail 2 "usage: configure-host-usb.sh ROOT BFU_ROOT"
[ "$1" = "$ROOT" ] || fail 3 "only $ROOT is allowed"
BFU_ROOT="$2"
case "$BFU_ROOT" in
    /*) ;;
    *) fail 3 "BFU root must be absolute" ;;
esac
case "$BFU_ROOT" in
    /data/data/*|/data/user/*) fail 3 "BFU control files must use Device Protected Storage" ;;
esac

BIN="$BFU_ROOT/bin"
TOOLBOX="$BIN/busybox"
[ -x "$TOOLBOX" ] || fail 10 "source-built DawnShell toolbox is missing"
export PATH="$BIN:/system/bin:/system/xbin"
"$TOOLBOX" --install -s "$BIN" || fail 10 "could not provision toolbox applets"
for tool in awk cat chmod chown grep id mkdir mv pwd rm sed sha256sum stat; do
    command -v "$tool" >/dev/null 2>&1 || fail 10 "missing bootstrap applet: $tool"
done

[ "$(id -u)" = 0 ] || fail 11 "USB policy did not obtain uid 0"
if [ ! -d "$ROOT" ] || [ -L "$ROOT" ]; then
    fail 13 "rootfs is missing or is a symlink"
fi
RESOLVED_ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || fail 13 "rootfs path could not be resolved"
[ "$RESOLVED_ROOT" = "$ROOT" ] || fail 13 "rootfs resolves elsewhere"
[ "$(stat -c '%u:%g' "$ROOT")" = "0:0" ] || fail 13 "rootfs is not root-owned"
[ -f "$ROOT/.dawnshell-rootfs" ] || fail 14 "DawnShell rootfs marker is missing"
grep -Fqx 'suite=trixie' "$ROOT/.dawnshell-rootfs" || fail 14 "rootfs is not Debian 13 Trixie"

wrapper="$ROOT/usr/local/bin/lsusb"
wrapper_hash="$ROOT/etc/dawnshell/lsusb-wrapper.sha256"
for parent in "$ROOT/usr" "$ROOT/usr/local" "$ROOT/etc"; do
    [ ! -L "$parent" ] || fail 19 "rootfs management path is a symlink: $parent"
done
mkdir -p "$ROOT/usr/local/bin" "$ROOT/etc/dawnshell"
for parent in "$ROOT/usr/local/bin" "$ROOT/etc/dawnshell"; do
    if [ ! -d "$parent" ] || [ -L "$parent" ]; then
        fail 19 "rootfs management directory is unsafe: $parent"
    fi
    [ "$(stat -c '%u:%g' "$parent")" = "0:0" ] || \
        fail 19 "rootfs management directory is not root-owned: $parent"
done

if [ -e "$wrapper" ]; then
    if [ ! -f "$wrapper" ] || [ -L "$wrapper" ]; then
        fail 20 "existing non-regular /usr/local/bin/lsusb was preserved"
    fi
    [ -f "$wrapper_hash" ] || fail 20 "existing unmanaged /usr/local/bin/lsusb was preserved"
    expected="$(sed -n '1p' "$wrapper_hash")"
    actual="$(sha256sum "$wrapper" | awk '{print $1}')"
    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
        fail 20 "managed lsusb wrapper was modified; refusing to overwrite it"
    fi
fi

temporary="${wrapper}.dawnshell.$$"
cat > "$temporary" <<'EOF_LSUSB'
#!/bin/bash
set -e

real_lsusb=/usr/bin/lsusb
[ -x "$real_lsusb" ] || {
    echo "lsusb: /usr/bin/lsusb is missing; install usbutils" >&2
    exit 127
}

# Debian 13 usbutils queries USB lane attributes introduced after Linux 4.4.
# Hide only those known ENOENT diagnostics; preserve every other stderr line.
exec "$real_lsusb" "$@" 2> >(
    while IFS= read -r line; do
        case "$line" in
            "unable to initialize usb spec") ;;
            /sys/bus/usb/devices/*/rx_lanes:\ No\ such\ file\ or\ directory) ;;
            /sys/bus/usb/devices/*/tx_lanes:\ No\ such\ file\ or\ directory) ;;
            *) printf '%s\n' "$line" >&2 ;;
        esac
    done
)
EOF_LSUSB
chmod 0755 "$temporary"
chown 0:0 "$temporary"
new_hash="$(sha256sum "$temporary" | awk '{print $1}')"
mv "$temporary" "$wrapper"
printf '%s\n' "$new_hash" > "$wrapper_hash"
chmod 0600 "$wrapper_hash"
chown 0:0 "$wrapper_hash"

echo "HOST_USB_TOOLING_SUCCEEDED: lsusb_legacy_sysfs_filter=enabled"
