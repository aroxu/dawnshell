#!/system/bin/sh
set -u

PATH=/system/bin:/system/xbin
export PATH

if [ "$#" -ne 1 ]; then
    echo "Debian-rootfs-access-failed stage=invalid_argument_count"
    exit 19
fi
ROOT="$1"
case "$ROOT" in
    /*) ;;
    *)
        echo "Debian-rootfs-access-failed stage=non_absolute_root"
        exit 19
        ;;
esac

fail() {
    echo "Debian-rootfs-access-failed stage=$1 root=$ROOT"
    exit "$2"
}

[ -d "$ROOT" ] || fail root_missing 20
[ -d "$ROOT/etc" ] || fail etc_missing 21
[ -f "$ROOT/bin/sh" ] || fail shell_missing 22
[ -r "$ROOT/bin/sh" ] || fail shell_not_readable 23
[ -x "$ROOT/bin/sh" ] || fail shell_not_executable 24

PROBE="$ROOT/.dawnshell-access-probe.$$"
trap '/system/bin/rm -f "$PROBE"' 0 1 2 3 15
TOKEN="dawnshell-rootfs-probe-$$"
umask 077

printf '%s\n' "$TOKEN" > "$PROBE" || fail write_failed 25
READBACK="$(/system/bin/cat "$PROBE")" || fail read_failed 26
[ "$READBACK" = "$TOKEN" ] || fail content_mismatch 27
/system/bin/rm -f "$PROBE" || fail cleanup_failed 28
trap - 0 1 2 3 15

echo "Debian-rootfs-access-ok root=$ROOT shell=$ROOT/bin/sh rw=true"
