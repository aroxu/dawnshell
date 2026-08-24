#!/system/bin/sh
set -eu

# Uses only the source-built BFU toolbox in Device Protected Storage.

ROOT=/data/local/debian
SUITE=trixie
SSH_USER=debian
SSH_PORT=22

fail() {
    code="$1"
    shift
    echo "ERROR: $*"
    exit "$code"
}

[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || \
    fail 2 "usage: configure-debian-systemd.sh ROOT BFU_ROOT AUTHORIZED_KEYS DEBIAN_ARCH [--inside-mount-ns]"

REQUESTED_ROOT="$1"
BFU_ROOT="$2"
AUTHORIZED_KEYS="$3"
EXPECTED_ARCH="$4"
MODE="${5-}"
BIN="$BFU_ROOT/bin"
TOOLBOX="$BIN/busybox"

[ "$REQUESTED_ROOT" = "$ROOT" ] || fail 3 "only $ROOT is allowed"
case "$BFU_ROOT" in
    /*) ;;
    *) fail 3 "BFU root must be absolute" ;;
esac
case "$BFU_ROOT" in
    /data/data/*|/data/user/*)
        fail 3 "BFU control files must be in Device Protected Storage"
        ;;
esac
[ "$AUTHORIZED_KEYS" = "$BFU_ROOT/etc/authorized_keys" ] || \
    fail 3 "authorized_keys must be the provisioned DE file"
case "$EXPECTED_ARCH" in
    armhf|arm64|amd64) ;;
    *) fail 3 "unsupported Debian architecture: $EXPECTED_ARCH" ;;
esac

if [ "$MODE" != "--inside-mount-ns" ]; then
    [ -x "$TOOLBOX" ] || fail 10 "source-built DawnShell toolbox is missing"
    echo "Creating private AFU mount namespace for Debian configuration"
    exec "$TOOLBOX" unshare --mount --fork \
        /system/bin/sh "$0" "$ROOT" "$BFU_ROOT" "$AUTHORIZED_KEYS" \
        "$EXPECTED_ARCH" --inside-mount-ns
fi

umask 022
export PATH="$BIN:/system/bin:/system/xbin"
export HOME="$BFU_ROOT/home"
export TMPDIR="$BFU_ROOT/tmp"
unset LD_PRELOAD || true

"$TOOLBOX" --install -s "$BIN" || \
    fail 10 "could not provision bootstrap toolbox applets"

for tool in awk cat chroot chmod chown cp date grep id mkdir mount mv \
    readlink rm rmdir sed stat sync tr; do
    command -v "$tool" >/dev/null 2>&1 || \
        fail 10 "source-built bootstrap applet is missing: $tool"
done

[ "$(id -u)" = "0" ] || fail 11 "configuration did not obtain uid 0"
[ -d "$ROOT" ] || fail 13 "rootfs is missing: $ROOT"
[ ! -L "$ROOT" ] || fail 13 "rootfs symlinks are forbidden"
RESOLVED_ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || \
    fail 13 "rootfs path could not be resolved"
[ "$RESOLVED_ROOT" = "$ROOT" ] || fail 13 "rootfs resolves elsewhere"
[ "$(stat -c '%u:%g' "$ROOT")" = "0:0" ] || fail 13 "rootfs is not root-owned"
[ -f "$ROOT/.dawnshell-rootfs" ] || fail 14 "DawnShell rootfs marker is missing"
grep -Fqx "suite=$SUITE" "$ROOT/.dawnshell-rootfs" || \
    fail 14 "rootfs is not Debian 13 Trixie"
ROOTFS_ARCH="$(sed -n 's/^architecture=//p' "$ROOT/.dawnshell-rootfs" | head -n 1)"
case "$ROOTFS_ARCH" in
    armhf|arm64|amd64) ;;
    *) fail 14 "rootfs has an unsupported architecture: $ROOTFS_ARCH" ;;
esac
[ "$ROOTFS_ARCH" = "$EXPECTED_ARCH" ] || \
    fail 14 "rootfs architecture $ROOTFS_ARCH does not match app runtime $EXPECTED_ARCH"
[ -x "$ROOT/bin/bash" ] || fail 15 "rootfs has no executable /bin/bash"
[ -f "$AUTHORIZED_KEYS" ] || fail 16 "save at least one SSH public key first"
[ ! -L "$AUTHORIZED_KEYS" ] || fail 16 "authorized_keys symlinks are forbidden"
[ -x "$BIN/dawnshell-codec" ] || fail 16 "source-built hardware codec client is missing"
[ -f "$BFU_ROOT/scripts/dawnshell-codec-ffmpeg.py" ] || \
    fail 16 "hardware codec FFmpeg adapter is missing"
[ ! -L "$BFU_ROOT/scripts/dawnshell-codec-ffmpeg.py" ] || \
    fail 16 "hardware codec FFmpeg adapter symlinks are forbidden"
[ -f "$BFU_ROOT/scripts/dawnshell-codec-long-run.sh" ] || \
    fail 16 "hardware codec long-run test is missing"
[ ! -L "$BFU_ROOT/scripts/dawnshell-codec-long-run.sh" ] || \
    fail 16 "hardware codec long-run test symlinks are forbidden"
[ -f "$BFU_ROOT/scripts/dawnshell-codec-concurrency-test.sh" ] || \
    fail 16 "hardware codec concurrency test is missing"
[ ! -L "$BFU_ROOT/scripts/dawnshell-codec-concurrency-test.sh" ] || \
    fail 16 "hardware codec concurrency test symlinks are forbidden"
[ -f "$BFU_ROOT/scripts/dawnshell-codec-error-test.sh" ] || \
    fail 16 "hardware codec error test is missing"
[ ! -L "$BFU_ROOT/scripts/dawnshell-codec-error-test.sh" ] || \
    fail 16 "hardware codec error test symlinks are forbidden"
[ -f "$BFU_ROOT/downloads/avc-baseline-128x96-10fps.h264" ] || \
    fail 16 "hardware codec test vector is missing"
[ -f "$BFU_ROOT/downloads/avc-baseline-128x96-10fps.properties" ] || \
    fail 16 "hardware codec test metadata is missing"
for performance_asset in \
    avc-baseline-1280x720-30fps-30f.h264 \
    avc-baseline-1280x720-30fps-30f.properties \
    avc-high-1920x1080-30fps-60f.h264 \
    avc-high-1920x1080-30fps-60f.properties \
    avc-high-1280x720-30fps-30f-b2.mp4 \
    avc-high-1280x720-30fps-30f-b2.properties \
    hevc-main-1920x1080-30fps-60f.mp4 \
    hevc-main-1920x1080-30fps-60f.properties; do
    [ -f "$BFU_ROOT/downloads/$performance_asset" ] || \
        fail 16 "hardware codec performance asset is missing: $performance_asset"
    [ ! -L "$BFU_ROOT/downloads/$performance_asset" ] || \
        fail 16 "hardware codec performance asset symlinks are forbidden"
done

key_size="$(stat -c '%s' "$AUTHORIZED_KEYS")"
case "$key_size" in
    ''|*[!0-9]*) fail 16 "could not determine authorized_keys size" ;;
esac
if [ "$key_size" -le 0 ] || [ "$key_size" -gt 32768 ]; then
    fail 16 "authorized_keys must contain 1..32768 bytes"
fi

echo "Making Android mounts recursively private"
mount --make-rprivate /

LOCK_DIR=/data/local/.dawnshell-debian-config.lock
LOCK_HELD=false
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$LOCK_HELD" = true ]; then
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR"
    fi
    if [ "$result" -ne 0 ]; then
        echo "CONFIGURE_FAILED: exit=$result"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    old_pid="$(cat "$LOCK_DIR/owner" 2>/dev/null || true)"
    old_command=""
    case "$old_pid" in
        ''|*[!0-9]*) ;;
        *)
            if [ -r "/proc/$old_pid/cmdline" ]; then
                old_command="$(tr '\000' ' ' < "/proc/$old_pid/cmdline")"
            fi
            ;;
    esac
    case "$old_command" in
        *configure-debian-systemd.sh*)
            fail 17 "another Debian configuration is active as host pid $old_pid"
            ;;
    esac
    stale_lock="${LOCK_DIR}.stale.$(date +%s)"
    echo "Preserving stale configuration lock as $stale_lock"
    mv "$LOCK_DIR" "$stale_lock"
    mkdir "$LOCK_DIR" || fail 17 "could not acquire configuration lock"
fi
LOCK_HELD=true
echo "$$" > "$LOCK_DIR/owner"

for directory in dev proc sys run; do
    [ -d "$ROOT/$directory" ] || fail 18 "missing rootfs mount directory: /$directory"
done

echo "Binding /dev and /sys; mounting private /proc and /run"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
mount --rbind /sys "$ROOT/sys"
mount --make-rslave "$ROOT/sys"
mount -t proc -o nosuid,nodev,noexec proc "$ROOT/proc"
mount -t tmpfs -o nosuid,nodev,mode=0755,size=64m tmpfs "$ROOT/run"
mkdir -p "$ROOT/run/lock"

cp "$AUTHORIZED_KEYS" "$ROOT/run/dawnshell-authorized-keys"
chmod 0600 "$ROOT/run/dawnshell-authorized-keys"
chown 0:0 "$ROOT/run/dawnshell-authorized-keys"

# The client is a static Android ELF, so it remains executable inside the
# Debian chroot without exposing /system or app-private libraries.
mkdir -p "$ROOT/usr/local/bin"
for destination in "$ROOT/usr/local" "$ROOT/usr/local/bin"; do
    if [ ! -d "$destination" ] || [ -L "$destination" ]; then
        fail 18 "rootfs codec client destination is unsafe: $destination"
    fi
    [ "$(stat -c '%u:%g' "$destination")" = "0:0" ] || \
        fail 18 "rootfs codec client destination is not root-owned: $destination"
done
cp "$BIN/dawnshell-codec" "$ROOT/usr/local/bin/dawnshell-codec.new"
chown 0:0 "$ROOT/usr/local/bin/dawnshell-codec.new"
chmod 0755 "$ROOT/usr/local/bin/dawnshell-codec.new"
mv "$ROOT/usr/local/bin/dawnshell-codec.new" \
    "$ROOT/usr/local/bin/dawnshell-codec"
mkdir -p "$ROOT/usr/local/libexec"
if [ ! -d "$ROOT/usr/local/libexec" ] || [ -L "$ROOT/usr/local/libexec" ]; then
    fail 18 "rootfs codec adapter destination is unsafe"
fi
[ "$(stat -c '%u:%g' "$ROOT/usr/local/libexec")" = "0:0" ] || \
    fail 18 "rootfs codec adapter destination is not root-owned"
cp "$BFU_ROOT/scripts/dawnshell-codec-ffmpeg.py" \
    "$ROOT/usr/local/libexec/dawnshell-codec-ffmpeg.py.new"
chown 0:0 "$ROOT/usr/local/libexec/dawnshell-codec-ffmpeg.py.new"
chmod 0755 "$ROOT/usr/local/libexec/dawnshell-codec-ffmpeg.py.new"
mv "$ROOT/usr/local/libexec/dawnshell-codec-ffmpeg.py.new" \
    "$ROOT/usr/local/libexec/dawnshell-codec-ffmpeg.py"
cp "$BFU_ROOT/scripts/dawnshell-codec-long-run.sh" \
    "$ROOT/usr/local/bin/dawnshell-codec-long-run.new"
chown 0:0 "$ROOT/usr/local/bin/dawnshell-codec-long-run.new"
chmod 0755 "$ROOT/usr/local/bin/dawnshell-codec-long-run.new"
mv "$ROOT/usr/local/bin/dawnshell-codec-long-run.new" \
    "$ROOT/usr/local/bin/dawnshell-codec-long-run"
cp "$BFU_ROOT/scripts/dawnshell-codec-concurrency-test.sh" \
    "$ROOT/usr/local/bin/dawnshell-codec-concurrency-test.new"
chown 0:0 "$ROOT/usr/local/bin/dawnshell-codec-concurrency-test.new"
chmod 0755 "$ROOT/usr/local/bin/dawnshell-codec-concurrency-test.new"
mv "$ROOT/usr/local/bin/dawnshell-codec-concurrency-test.new" \
    "$ROOT/usr/local/bin/dawnshell-codec-concurrency-test"
cp "$BFU_ROOT/scripts/dawnshell-codec-error-test.sh" \
    "$ROOT/usr/local/bin/dawnshell-codec-error-test.new"
chown 0:0 "$ROOT/usr/local/bin/dawnshell-codec-error-test.new"
chmod 0755 "$ROOT/usr/local/bin/dawnshell-codec-error-test.new"
mv "$ROOT/usr/local/bin/dawnshell-codec-error-test.new" \
    "$ROOT/usr/local/bin/dawnshell-codec-error-test"
mkdir -p "$ROOT/usr/local/share/dawnshell"
for destination in "$ROOT/usr/local/share" "$ROOT/usr/local/share/dawnshell"; do
    if [ ! -d "$destination" ] || [ -L "$destination" ]; then
        fail 18 "rootfs codec test destination is unsafe: $destination"
    fi
    [ "$(stat -c '%u:%g' "$destination")" = "0:0" ] || \
        fail 18 "rootfs codec test destination is not root-owned: $destination"
done
cp "$BFU_ROOT/downloads/avc-baseline-128x96-10fps.h264" \
    "$ROOT/usr/local/share/dawnshell/avc-baseline-128x96-10fps.h264"
cp "$BFU_ROOT/downloads/avc-baseline-128x96-10fps.properties" \
    "$ROOT/usr/local/share/dawnshell/avc-baseline-128x96-10fps.properties"
chown 0:0 "$ROOT/usr/local/share/dawnshell/"avc-baseline-128x96-10fps.*
chmod 0644 "$ROOT/usr/local/share/dawnshell/"avc-baseline-128x96-10fps.*
for performance_asset in \
    avc-baseline-1280x720-30fps-30f.h264 \
    avc-baseline-1280x720-30fps-30f.properties \
    avc-high-1920x1080-30fps-60f.h264 \
    avc-high-1920x1080-30fps-60f.properties \
    avc-high-1280x720-30fps-30f-b2.mp4 \
    avc-high-1280x720-30fps-30f-b2.properties \
    hevc-main-1920x1080-30fps-60f.mp4 \
    hevc-main-1920x1080-30fps-60f.properties; do
    cp "$BFU_ROOT/downloads/$performance_asset" \
        "$ROOT/usr/local/share/dawnshell/$performance_asset"
    chown 0:0 "$ROOT/usr/local/share/dawnshell/$performance_asset"
    chmod 0644 "$ROOT/usr/local/share/dawnshell/$performance_asset"
done

dns="$(getprop net.dns1 2>/dev/null || true)"
case "$dns" in
    ''|*[!0-9a-fA-F:.]*) dns=1.1.1.1 ;;
esac
printf 'nameserver %s\nnameserver 1.1.1.1\noptions timeout:2 attempts:3\n' "$dns" \
    > "$ROOT/etc/resolv.conf"
chmod 0644 "$ROOT/etc/resolv.conf"
chown 0:0 "$ROOT/etc/resolv.conf"

echo "Entering Debian 13 Trixie for systemd, D-Bus, and OpenSSH setup"
container=dawnshell DEBIAN_FRONTEND=noninteractive \
    chroot "$ROOT" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    DAWNSHELL_DEBIAN_ARCH="$ROOTFS_ARCH" \
    container=dawnshell \
    DEBIAN_FRONTEND=noninteractive \
    /bin/bash -s <<'DEBIAN_CONFIG'
set -Eeuo pipefail

READY_MARKER=/.dawnshell-systemd-ready
POLICY=/usr/sbin/policy-rc.d
POLICY_BACKUP=/run/dawnshell-policy-rc.d.backup
POLICY_EXISTED=false

restore_policy() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$POLICY_EXISTED" = true ]; then
        rm -f "$POLICY"
        cp -a "$POLICY_BACKUP" "$POLICY"
    elif grep -Fq 'DAWNSHELL_POLICY' "$POLICY" 2>/dev/null; then
        rm -f "$POLICY"
    fi
    exit "$result"
}
trap restore_policy EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rm -f "$READY_MARKER"

source /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || {
    echo "ERROR: expected Debian Trixie"
    exit 30
}
[ "$(dpkg --print-architecture)" = "$DAWNSHELL_DEBIAN_ARCH" ] || {
    echo "ERROR: expected Debian $DAWNSHELL_DEBIAN_ARCH"
    exit 31
}

if [ -e "$POLICY" ]; then
    cp -a "$POLICY" "$POLICY_BACKUP"
    POLICY_EXISTED=true
fi
cat > "$POLICY" <<'EOF_POLICY'
#!/bin/sh
# DAWNSHELL_POLICY
exit 101
EOF_POLICY
chmod 0755 "$POLICY"

cat > /etc/apt/sources.list <<'EOF_APT_HTTP'
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
deb http://deb.debian.org/debian-security trixie-security main
EOF_APT_HTTP

echo "STAGE: Updating signed Debian package indexes"
apt-get -o Acquire::Retries=3 update
echo "STAGE: Installing Debian systemd, D-Bus, OpenSSH, and diagnostics"
apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    systemd systemd-sysv dbus openssh-server iproute2 procps ca-certificates \
    bash passwd mawk time util-linux usbutils ffmpeg python3-minimal

cat > /etc/apt/sources.list <<'EOF_APT_HTTPS'
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://deb.debian.org/debian-security trixie-security main
EOF_APT_HTTPS
apt-get -o Acquire::Retries=3 update

for tool in /sbin/init /usr/bin/systemctl /usr/bin/journalctl /usr/bin/busctl \
    /usr/bin/timeout /usr/bin/ss /usr/bin/mawk /usr/bin/touch \
    /usr/bin/mktemp /usr/bin/sha256sum /usr/bin/sleep /usr/bin/time /usr/bin/flock \
    /usr/bin/lsusb /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/python3 \
    /usr/sbin/shutdown; do
    [ -x "$tool" ] || {
        echo "ERROR: required BFU health tool is missing: $tool"
        exit 35
    }
done
[ -x /usr/local/bin/dawnshell-codec ] || {
    echo "ERROR: DawnShell hardware codec client is missing"
    exit 35
}
cat > /usr/local/bin/dawnshell-codec-self-test <<'EOF_CODEC_SELF_TEST'
#!/bin/sh
set -eu
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ "${DAWNSHELL_CODEC_TEST_LOCK_HELD:-0}" != 1 ]; then
    install -d -m 0700 -o root -g root /var/lib/dawnshell
    exec 9> /var/lib/dawnshell/codec-test.lock
    /usr/bin/flock -n 9 || {
        echo "Another DawnShell hardware codec test is already running" >&2
        exit 75
    }
    export DAWNSHELL_CODEC_TEST_LOCK_HELD=1
fi
vector=/usr/local/share/dawnshell/avc-baseline-128x96-10fps.h264
expected=777feb39bd92b899fc9cf7c184396e3ecec4fdbcd7a582fc560fc37011f18053
temporary="$(mktemp /run/dawnshell-codec-i420.XXXXXX)"
encoded="$(mktemp /run/dawnshell-codec-h264.XXXXXX)"
transcoded="$(mktemp /run/dawnshell-codec-transcode.XXXXXX)"
cleanup() {
    rm -f "$temporary" "$encoded" "$transcoded" "$transcoded.h264"
}
trap cleanup EXIT HUP INT TERM
/usr/local/bin/dawnshell-codec health --format json
/usr/local/bin/dawnshell-codec negative-test
/usr/local/bin/dawnshell-codec decode-test "$vector" 128 96 10 10 > "$temporary"
actual="$(sha256sum "$temporary" | awk '{print $1}')"
[ "$actual" = "$expected" ] || {
    echo "hardware AVC decode checksum mismatch: $actual" >&2
    exit 1
}
echo "DawnShell hardware AVC decode passed: frames=10 pts=exact i420_sha256=$actual"
/usr/local/bin/dawnshell-codec encode-test 128 96 10 10 1000000 > "$encoded"
ffmpeg -hide_banner -loglevel error -f h264 -i "$encoded" -f null -
encoded_frames="$(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 \
    "$encoded")"
[ "$encoded_frames" = 10 ] || {
    echo "hardware AVC encode frame count mismatch: $encoded_frames" >&2
    exit 1
}
echo "DawnShell hardware AVC encode passed: frames=10 pts=exact ffmpeg_decode=passed"
/usr/local/bin/dawnshell-hwtranscode "$vector" "$transcoded.h264" 1000000
transcoded_frames="$(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 \
    "$transcoded.h264")"
[ "$transcoded_frames" = 10 ] || {
    echo "hardware Surface transcode frame count mismatch: $transcoded_frames" >&2
    exit 1
}
echo "DawnShell Surface zero-copy AVC transcode passed: frames=10"
/usr/local/bin/dawnshell-codec health --format json
EOF_CODEC_SELF_TEST
chmod 0755 /usr/local/bin/dawnshell-codec-self-test

cat > /usr/local/bin/dawnshell-codec-performance-test <<'EOF_CODEC_PERFORMANCE_TEST'
#!/bin/sh
set -eu
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ "${DAWNSHELL_CODEC_TEST_LOCK_HELD:-0}" != 1 ]; then
    install -d -m 0700 -o root -g root /var/lib/dawnshell
    exec 9> /var/lib/dawnshell/codec-test.lock
    /usr/bin/flock -n 9 || {
        echo "Another DawnShell hardware codec test is already running" >&2
        exit 75
    }
    export DAWNSHELL_CODEC_TEST_LOCK_HELD=1
fi

adapter=/usr/local/libexec/dawnshell-codec-ffmpeg.py
vector_720=/usr/local/share/dawnshell/avc-baseline-1280x720-30fps-30f.h264
vector_1080=/usr/local/share/dawnshell/avc-high-1920x1080-30fps-60f.h264
vector_bframes=/usr/local/share/dawnshell/avc-high-1280x720-30fps-30f-b2.mp4
vector_hevc=/usr/local/share/dawnshell/hevc-main-1920x1080-30fps-60f.mp4
expected_720=7ff494db80cf8a311468f9638384d3d7a7bd320b5b831110076b7c80979af26f
expected_1080=48630f45fa17f58a0435ff0cdb18e42ae466a449cd5d7f7ba966f277b2c8082e
expected_bframes=484b59dce2d3a1ce58d0712583309f0a1ad8b0e0506ab226fb95191ef67cf437
temporary="$(mktemp -d /run/dawnshell-codec-performance.XXXXXX)"
cleanup() {
    rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

before_health="$temporary/health-before.json"
after_health="$temporary/health-after.json"
decoded="$temporary/decoded.i420"
shared_log="$temporary/decode-shared.log"
socket_log="$temporary/decode-socket.log"
transcode_log="$temporary/transcode.log"
encoded="$temporary/transcoded.h264"
bframe_decoded="$temporary/bframe-decoded.i420"
bframe_log="$temporary/bframe-decode.log"
hevc_encoded="$temporary/hevc-transcoded.h264"
hevc_log="$temporary/hevc-transcode.log"
software_time="$temporary/software-decode.time"
hardware_time="$temporary/hardware-decode.time"
software_hash="$temporary/software-decode.sha256"
hardware_hash="$temporary/hardware-decode.sha256"
baseline_before="$temporary/baseline-before.json"
baseline_after="$temporary/baseline-after.json"
baseline_decode_log="$temporary/baseline-decode.log"
baseline_ffmpeg_log="$temporary/baseline-ffmpeg.log"
baseline_json="$temporary/cpu-baseline.json"
quality_encoded="$temporary/quality-encoded.h264"
quality_wrapper_log="$temporary/quality-wrapper.log"
quality_encode_log="$temporary/quality-encode.log"
quality_psnr_log="$temporary/quality-psnr.log"
quality_ssim_log="$temporary/quality-ssim.log"
quality_json="$temporary/quality.json"

dawnshell-codec health --format json > "$before_health"

echo "STAGE: 720p hardware decode through shared memory"
if dawnshell-codec decode-test "$vector_720" 1280 720 30 30 \
    > "$decoded" 2> "$shared_log"; then
    :
else
    status=$?
    cat "$shared_log" >&2
    exit "$status"
fi
actual="$(sha256sum "$decoded" | awk '{print $1}')"
[ "$actual" = "$expected_720" ] || {
    cat "$shared_log" >&2
    echo "720p shared-memory decode checksum mismatch: $actual" >&2
    exit 1
}
rm -f "$decoded"

echo "STAGE: 720p hardware decode through bounded socket fallback"
if DAWNSHELL_CODEC_DISABLE_SHM=1 \
    dawnshell-codec decode-test "$vector_720" 1280 720 30 30 \
    > "$decoded" 2> "$socket_log"; then
    :
else
    status=$?
    cat "$socket_log" >&2
    exit "$status"
fi
actual="$(sha256sum "$decoded" | awk '{print $1}')"
[ "$actual" = "$expected_720" ] || {
    cat "$socket_log" >&2
    echo "720p socket decode checksum mismatch: $actual" >&2
    exit 1
}
rm -f "$decoded"
"$adapter" compare-decode-transports "$shared_log" "$socket_log" 30

echo "STAGE: MP4 B-frame demux, timestamp reorder, and hardware decode"
if dawnshell-hwdecode "$vector_bframes" "$bframe_decoded" \
    > "$temporary/bframe-wrapper.log" 2> "$bframe_log"; then
    :
else
    status=$?
    cat "$temporary/bframe-wrapper.log" "$bframe_log" >&2
    exit "$status"
fi
actual="$(sha256sum "$bframe_decoded" | awk '{print $1}')"
[ "$actual" = "$expected_bframes" ] || {
    cat "$bframe_log" >&2
    echo "B-frame MP4 hardware decode checksum mismatch: $actual" >&2
    exit 1
}
"$adapter" validate-decoder-stats "$bframe_log" 30
rm -f "$bframe_decoded"

echo "STAGE: software-versus-hardware 1080p decode CPU baseline"
# shellcheck disable=SC2016 # Positional arguments expand in the child shell.
if /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kb=%M' \
    -o "$software_time" /bin/sh -c '
        ffmpeg -hide_banner -loglevel error -f h264 -i "$1" -map 0:v:0 \
            -an -pix_fmt yuv420p -f rawvideo pipe:1 2> "$2" \
            | sha256sum > "$3"
    ' dawnshell-codec-software-baseline "$vector_1080" \
        "$baseline_ffmpeg_log" "$software_hash"; then
    :
else
    status=$?
    cat "$baseline_ffmpeg_log" >&2
    exit "$status"
fi
[ "$(awk '{print $1}' "$software_hash")" = "$expected_1080" ] || {
    cat "$baseline_ffmpeg_log" >&2
    echo "software 1080p decode checksum mismatch" >&2
    exit 1
}
dawnshell-codec health --format json > "$baseline_before"
# shellcheck disable=SC2016 # Positional arguments expand in the child shell.
if /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kb=%M' \
    -o "$hardware_time" /bin/sh -c '
        dawnshell-codec decode-test "$1" 1920 1080 30 60 2> "$2" \
            | sha256sum > "$3"
    ' dawnshell-codec-hardware-baseline "$vector_1080" \
        "$baseline_decode_log" "$hardware_hash"; then
    :
else
    status=$?
    cat "$baseline_decode_log" >&2
    exit "$status"
fi
[ "$(awk '{print $1}' "$hardware_hash")" = "$expected_1080" ] || {
    cat "$baseline_decode_log" >&2
    echo "hardware 1080p decode checksum mismatch" >&2
    exit 1
}
dawnshell-codec health --format json > "$baseline_after"
"$adapter" compare-cpu-baseline "$baseline_before" "$baseline_after" \
    "$hardware_time" "$software_time" "$baseline_json"
cat "$baseline_json"

echo "STAGE: 1080p hardware encode frame count and objective quality"
if dawnshell-hwencode "$vector_1080" "$quality_encoded" 8000000 \
    > "$quality_wrapper_log" 2> "$quality_encode_log"; then
    :
else
    status=$?
    cat "$quality_wrapper_log" "$quality_encode_log" >&2
    exit "$status"
fi
ffmpeg -hide_banner -nostdin -f h264 -i "$quality_encoded" \
    -f h264 -i "$vector_1080" \
    -lavfi '[0:v]setpts=PTS-STARTPTS[distorted];[1:v]setpts=PTS-STARTPTS[reference];[distorted][reference]psnr' \
    -frames:v 60 -f null - 2> "$quality_psnr_log"
ffmpeg -hide_banner -nostdin -f h264 -i "$quality_encoded" \
    -f h264 -i "$vector_1080" \
    -lavfi '[0:v]setpts=PTS-STARTPTS[distorted];[1:v]setpts=PTS-STARTPTS[reference];[distorted][reference]ssim' \
    -frames:v 60 -f null - 2> "$quality_ssim_log"
"$adapter" validate-quality "$quality_psnr_log" "$quality_ssim_log" \
    30.0 0.90 --output "$quality_json"
cat "$quality_json"

echo "STAGE: 1080p30 Surface zero-copy realtime transcode"
if dawnshell-codec transcode-test "$vector_1080" 1920 1080 30 60 8000000 \
    > "$encoded" 2> "$transcode_log"; then
    :
else
    status=$?
    cat "$transcode_log" >&2
    exit "$status"
fi
"$adapter" validate-stats "$transcode_log" 60 --max-runtime-ms 2000
ffmpeg -hide_banner -loglevel error -f h264 -i "$encoded" -f null -
encoded_frames="$(ffprobe -v error -f h264 -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames \
    -of default=nokey=1:noprint_wrappers=1 "$encoded")"
[ "$encoded_frames" = 60 ] || {
    echo "1080p Surface transcode frame count mismatch: $encoded_frames" >&2
    exit 1
}

echo "STAGE: HEVC MP4 to AVC Surface zero-copy pipeline"
if dawnshell-hwtranscode "$vector_hevc" "$hevc_encoded" 8000000 \
    > "$temporary/hevc-wrapper.log" 2> "$hevc_log"; then
    :
else
    status=$?
    cat "$temporary/hevc-wrapper.log" "$hevc_log" >&2
    exit "$status"
fi
ffmpeg -hide_banner -loglevel error -f h264 -i "$hevc_encoded" -f null -
hevc_frames="$(ffprobe -v error -f h264 -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames \
    -of default=nokey=1:noprint_wrappers=1 "$hevc_encoded")"
[ "$hevc_frames" = 60 ] || {
    echo "HEVC Surface transcode frame count mismatch: $hevc_frames" >&2
    exit 1
}

echo "STAGE: abrupt peer cleanup and Surface resource reuse"
for _ in 1 2 3 4 5; do
    if ! dawnshell-codec orphan-test decode \
        >> "$temporary/orphan.log" 2>&1; then
        cat "$temporary/orphan.log" >&2
        exit 1
    fi
    sleep 1
done
for _ in 1 2; do
    if ! dawnshell-codec orphan-test transcode \
        >> "$temporary/orphan.log" 2>&1; then
        cat "$temporary/orphan.log" >&2
        exit 1
    fi
    sleep 1
done
dawnshell-codec health --format json > "$after_health"
"$adapter" validate-cleanup "$before_health" "$after_health" 14

echo "STAGE: malformed-input, EOS state-machine, and broker recovery regression"
/usr/local/bin/dawnshell-codec-error-test
echo "STAGE: bounded concurrent session regression"
/usr/local/bin/dawnshell-codec-concurrency-test

echo "DawnShell hardware codec performance test passed: 720p/1080p checksum and CPU baseline, B-frame MP4 decode, objective encode quality, shared-memory/socket comparison, AVC/HEVC Surface transcode, malformed-input isolation, concurrent sessions, cleanup"
EOF_CODEC_PERFORMANCE_TEST
chmod 0755 /usr/local/bin/dawnshell-codec-performance-test
chown 0:0 /usr/local/bin/dawnshell-codec-performance-test

[ -x /usr/local/libexec/dawnshell-codec-ffmpeg.py ] || {
    echo "ERROR: DawnShell FFmpeg packet adapter is missing"
    exit 35
}
cat > /usr/local/bin/dawnshell-hwdecode <<'EOF_CODEC_FFMPEG'
#!/bin/bash
set -euo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
    echo "usage: dawnshell-hwdecode INPUT OUTPUT" >&2
    echo "H.264 and HEVC inputs are hardware decoded. Raw I420 uses .i420/.yuv." >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
input="$1"
output="$2"
[ -f "$input" ] || {
    echo "dawnshell-hwdecode: input is not a regular file: $input" >&2
    exit 2
}
[ -n "$output" ] || usage

temporary="$(mktemp -d /run/dawnshell-hwdecode.XXXXXX)"
cleanup() {
    rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

stream_info="$temporary/stream.txt"
input_packets="$temporary/input-packets.json"
annex_b="$temporary/input.es"
raw_packets="$temporary/raw-packets.json"
framed_input="$temporary/framed-input.bin"
client_log="$temporary/client.log"
unpack_log="$temporary/unpack.log"
frame_count="$temporary/frame-count.txt"

ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate,bit_rate \
    -of default=noprint_wrappers=1 "$input" > "$stream_info"
codec="$(sed -n 's/^codec_name=//p' "$stream_info" | head -n 1)"
width="$(sed -n 's/^width=//p' "$stream_info" | head -n 1)"
height="$(sed -n 's/^height=//p' "$stream_info" | head -n 1)"
frame_rate="$(sed -n 's/^avg_frame_rate=//p' "$stream_info" | head -n 1)"
bit_rate="$(sed -n 's/^bit_rate=//p' "$stream_info" | head -n 1)"

case "$codec" in
    h264)
        input_codec=avc
        bitstream_filter=h264_mp4toannexb
        elementary_format=h264
        ;;
    hevc)
        input_codec=hevc
        bitstream_filter=hevc_mp4toannexb
        elementary_format=hevc
        ;;
    *)
        echo "dawnshell-hwdecode: input codec must be H.264 or HEVC; got ${codec:-unknown}" >&2
        exit 3
        ;;
esac
case "$width:$height" in
    *[!0-9:]*|:*|*:)
        echo "dawnshell-hwdecode: invalid video dimensions" >&2
        exit 3
        ;;
esac
if [ "$width" -lt 16 ] || [ "$height" -lt 16 ] || \
    [ "$width" -gt 4096 ] || [ "$height" -gt 4096 ] || \
    [ $((width % 2)) -ne 0 ] || [ $((height % 2)) -ne 0 ]; then
    echo "dawnshell-hwdecode: dimensions must be even and within 16..4096" >&2
    exit 3
fi
integer_rate="$(printf '%s\n' "$frame_rate" | mawk -F/ '
    NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 != 0 {
        rate = $1 / $2
        if (rate >= 1 && rate <= 240) printf "%d\n", int(rate + 0.5)
    }')"
case "$integer_rate" in
    ''|*[!0-9]*)
        echo "dawnshell-hwdecode: invalid average frame rate: ${frame_rate:-unknown}" >&2
        exit 3
        ;;
esac
case "$bit_rate" in
    ''|N/A|*[!0-9]*) bit_rate=4000000 ;;
esac
if [ "$bit_rate" -lt 1000 ] || [ "$bit_rate" -gt 1000000000 ]; then
    bit_rate=4000000
fi

echo "DawnShell hardware decode: codec=$input_codec size=${width}x${height} rate=$frame_rate"
ffprobe -v error -select_streams v:0 -show_packets \
    -show_entries packet=pts_time,dts_time -of json "$input" > "$input_packets"
ffmpeg -hide_banner -loglevel error -y -i "$input" -map 0:v:0 -an \
    -c:v copy -bsf:v "$bitstream_filter" -f "$elementary_format" "$annex_b"
ffprobe -v error -f "$elementary_format" -show_packets -show_entries packet=pos,size \
    -of json "$annex_b" > "$raw_packets"
/usr/local/libexec/dawnshell-codec-ffmpeg.py pack \
    "$input_packets" "$raw_packets" "$annex_b" "$frame_rate" "$framed_input"

case "$output" in
    *.i420|*.I420|*.yuv|*.YUV)
        if /usr/local/bin/dawnshell-codec pipe decode "$input_codec" "$width" "$height" \
            "$integer_rate" "$bit_rate" < "$framed_input" 2> "$client_log" \
            | /usr/local/libexec/dawnshell-codec-ffmpeg.py unpack \
                - "$output" "$width" "$height" > "$frame_count"; then
            :
        else
            status=$?
            cat "$client_log" >&2
            exit "$status"
        fi
        frames="$(cat "$frame_count")"
        ;;
    *)
        if /usr/local/bin/dawnshell-codec pipe decode "$input_codec" "$width" "$height" \
            "$integer_rate" "$bit_rate" < "$framed_input" 2> "$client_log" \
            | /usr/local/libexec/dawnshell-codec-ffmpeg.py unpack \
                - - "$width" "$height" 2> "$unpack_log" \
            | ffmpeg -hide_banner -loglevel error -y -f rawvideo \
                -pixel_format yuv420p -video_size "${width}x${height}" \
                -framerate "$frame_rate" -i pipe:0 -an -c:v libx264 \
                -pix_fmt yuv420p "$output"; then
            :
        else
            status=$?
            cat "$client_log" "$unpack_log" >&2
            exit "$status"
        fi
        frames="$(sed -n 's/^unpacked_i420_frames=//p' "$unpack_log" | tail -n 1)"
        ;;
esac
cat "$client_log" >&2
[ -n "$frames" ] || {
    echo "dawnshell-hwdecode: frame count was not reported" >&2
    exit 4
}
echo "DawnShell hardware decode complete: frames=$frames output=$output"
EOF_CODEC_FFMPEG
chmod 0755 /usr/local/bin/dawnshell-hwdecode
chown 0:0 /usr/local/bin/dawnshell-hwdecode

cat > /usr/local/bin/dawnshell-hwencode <<'EOF_CODEC_FFMPEG_ENCODE'
#!/bin/bash
set -euo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
    echo "usage: dawnshell-hwencode INPUT OUTPUT [BITRATE] [avc|hevc]" >&2
    echo "Codec defaults from a raw output suffix; otherwise AVC. Containers are stream-copied." >&2
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 4 ] || usage
input="$1"
output="$2"
bit_rate="${3:-4000000}"
codec="${4:-}"
[ -f "$input" ] || {
    echo "dawnshell-hwencode: input is not a regular file: $input" >&2
    exit 2
}
case "$bit_rate" in
    ''|*[!0-9]*) usage ;;
esac
if [ "$bit_rate" -lt 1000 ] || [ "$bit_rate" -gt 100000000 ]; then
    echo "dawnshell-hwencode: bitrate must be within 1000..100000000" >&2
    exit 2
fi
if [ -z "$codec" ]; then
    case "$output" in
        *.hevc|*.HEVC|*.h265|*.H265|*.265) codec=hevc ;;
        *) codec=avc ;;
    esac
fi
case "$codec" in
    avc)
        elementary_format=h264
        ;;
    hevc)
        elementary_format=hevc
        ;;
    *)
        echo "dawnshell-hwencode: codec must be avc or hevc" >&2
        exit 2
        ;;
esac

temporary="$(mktemp -d /run/dawnshell-hwencode.XXXXXX)"
cleanup() {
    rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM
stream_info="$temporary/stream.txt"
framed_output="$temporary/framed-output.bin"
annex_b="$temporary/output.es"
client_log="$temporary/client.log"
pack_log="$temporary/pack.log"
ffmpeg_log="$temporary/ffmpeg.log"

ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,avg_frame_rate \
    -of default=noprint_wrappers=1 "$input" > "$stream_info"
width="$(sed -n 's/^width=//p' "$stream_info" | head -n 1)"
height="$(sed -n 's/^height=//p' "$stream_info" | head -n 1)"
frame_rate="$(sed -n 's/^avg_frame_rate=//p' "$stream_info" | head -n 1)"
case "$width:$height" in
    *[!0-9:]*|:*|*:)
        echo "dawnshell-hwencode: invalid video dimensions" >&2
        exit 3
        ;;
esac
if [ "$width" -lt 16 ] || [ "$height" -lt 16 ] || \
    [ "$width" -gt 4096 ] || [ "$height" -gt 4096 ] || \
    [ $((width % 2)) -ne 0 ] || [ $((height % 2)) -ne 0 ]; then
    echo "dawnshell-hwencode: dimensions must be even and within 16..4096" >&2
    exit 3
fi
integer_rate="$(printf '%s\n' "$frame_rate" | mawk -F/ '
    NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 != 0 {
        rate = $1 / $2
        if (rate >= 1 && rate <= 240) printf "%d\n", int(rate + 0.5)
    }')"
case "$integer_rate" in
    ''|*[!0-9]*)
        echo "dawnshell-hwencode: invalid average frame rate: ${frame_rate:-unknown}" >&2
        exit 3
        ;;
esac

echo "DawnShell hardware encode: codec=$codec size=${width}x${height} rate=$frame_rate"
if ffmpeg -hide_banner -loglevel error -i "$input" -map 0:v:0 -an \
    -pix_fmt yuv420p -f rawvideo pipe:1 2> "$ffmpeg_log" \
    | /usr/local/libexec/dawnshell-codec-ffmpeg.py pack-i420 \
        - "$width" "$height" "$frame_rate" - 2> "$pack_log" \
    | /usr/local/bin/dawnshell-codec pipe encode "$codec" "$width" "$height" \
        "$integer_rate" "$bit_rate" > "$framed_output" 2> "$client_log"; then
    :
else
    status=$?
    cat "$ffmpeg_log" "$pack_log" "$client_log" >&2
    exit "$status"
fi
cat "$client_log" >&2
input_frames="$(sed -n 's/^packed_i420_frames=//p' "$pack_log" | tail -n 1)"
[ -n "$input_frames" ] || {
    echo "dawnshell-hwencode: input frame count was not reported" >&2
    exit 4
}
output_frames="$(/usr/local/libexec/dawnshell-codec-ffmpeg.py unpack-annexb \
    "$framed_output" "$annex_b" --require-keyframe)"
[ "$input_frames" = "$output_frames" ] || {
    echo "dawnshell-hwencode: frame count mismatch: $input_frames != $output_frames" >&2
    exit 4
}
/usr/local/libexec/dawnshell-codec-ffmpeg.py validate-encoder-stats \
    "$client_log" "$output_frames" "$integer_rate" "$bit_rate"
case "$codec:$output" in
    avc:*.h264|avc:*.H264|avc:*.264|hevc:*.hevc|hevc:*.HEVC|hevc:*.h265|hevc:*.H265|hevc:*.265)
        cp -- "$annex_b" "$output"
        ;;
    avc:*.hevc|avc:*.HEVC|avc:*.h265|avc:*.H265|avc:*.265|hevc:*.h264|hevc:*.H264|hevc:*.264)
        echo "dawnshell-hwencode: raw output suffix conflicts with codec $codec" >&2
        exit 4
        ;;
    *)
        ffmpeg -hide_banner -loglevel error -y -r "$frame_rate" -f "$elementary_format" \
            -i "$annex_b" -map 0:v:0 -an -c:v copy "$output"
        ;;
esac
echo "DawnShell hardware encode complete: frames=$output_frames output=$output"
EOF_CODEC_FFMPEG_ENCODE
chmod 0755 /usr/local/bin/dawnshell-hwencode
chown 0:0 /usr/local/bin/dawnshell-hwencode

cat > /usr/local/bin/dawnshell-hwtranscode <<'EOF_CODEC_SURFACE_TRANSCODE'
#!/bin/sh
set -eu
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
    echo "usage: dawnshell-hwtranscode INPUT OUTPUT [BITRATE]" >&2
    echo "H.264/HEVC input is decoded to an Android Surface and encoded as H.264." >&2
    exit 2
}

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
input="$1"
output="$2"
bit_rate="${3:-4000000}"
[ -f "$input" ] || {
    echo "dawnshell-hwtranscode: input is not a regular file: $input" >&2
    exit 2
}
case "$bit_rate" in
    ''|*[!0-9]*) usage ;;
esac
if [ "$bit_rate" -lt 1000 ] || [ "$bit_rate" -gt 100000000 ]; then
    echo "dawnshell-hwtranscode: bitrate must be within 1000..100000000" >&2
    exit 2
fi

temporary="$(mktemp -d /run/dawnshell-hwtranscode.XXXXXX)"
cleanup() {
    rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM
stream_info="$temporary/stream.txt"
input_packets="$temporary/input-packets.json"
annex_b="$temporary/input.bitstream"
raw_packets="$temporary/raw-packets.json"
framed_input="$temporary/framed-input.bin"
framed_output="$temporary/framed-output.bin"
encoded="$temporary/output.h264"
client_log="$temporary/client.log"

ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate \
    -of default=noprint_wrappers=1 "$input" > "$stream_info"
codec_name="$(sed -n 's/^codec_name=//p' "$stream_info" | head -n 1)"
width="$(sed -n 's/^width=//p' "$stream_info" | head -n 1)"
height="$(sed -n 's/^height=//p' "$stream_info" | head -n 1)"
frame_rate="$(sed -n 's/^avg_frame_rate=//p' "$stream_info" | head -n 1)"
case "$codec_name" in
    h264)
        input_codec=avc
        bitstream_filter=h264_mp4toannexb
        elementary_format=h264
        ;;
    hevc)
        input_codec=hevc
        bitstream_filter=hevc_mp4toannexb
        elementary_format=hevc
        ;;
    *)
        echo "dawnshell-hwtranscode: input codec must be H.264 or HEVC" >&2
        exit 3
        ;;
esac
case "$width:$height" in
    *[!0-9:]*|:*|*:)
        echo "dawnshell-hwtranscode: invalid video dimensions" >&2
        exit 3
        ;;
esac
if [ "$width" -lt 16 ] || [ "$height" -lt 16 ] || \
    [ "$width" -gt 4096 ] || [ "$height" -gt 4096 ] || \
    [ $((width % 2)) -ne 0 ] || [ $((height % 2)) -ne 0 ]; then
    echo "dawnshell-hwtranscode: dimensions must be even and within 16..4096" >&2
    exit 3
fi
integer_rate="$(printf '%s\n' "$frame_rate" | mawk -F/ '
    NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 != 0 {
        rate = $1 / $2
        if (rate >= 1 && rate <= 240) printf "%d\n", int(rate + 0.5)
    }')"
case "$integer_rate" in
    ''|*[!0-9]*)
        echo "dawnshell-hwtranscode: invalid frame rate: ${frame_rate:-unknown}" >&2
        exit 3
        ;;
esac

echo "DawnShell Surface transcode: ${codec_name}->h264 ${width}x${height} rate=$frame_rate"
ffprobe -v error -select_streams v:0 -show_packets \
    -show_entries packet=pts_time,dts_time -of json "$input" > "$input_packets"
ffmpeg -hide_banner -loglevel error -y -i "$input" -map 0:v:0 -an \
    -c:v copy -bsf:v "$bitstream_filter" -f "$elementary_format" "$annex_b"
ffprobe -v error -f "$elementary_format" -show_packets \
    -show_entries packet=pos,size -of json "$annex_b" > "$raw_packets"
/usr/local/libexec/dawnshell-codec-ffmpeg.py pack \
    "$input_packets" "$raw_packets" "$annex_b" "$frame_rate" "$framed_input"
if /usr/local/bin/dawnshell-codec transcode "$input_codec" avc "$width" "$height" \
    "$integer_rate" "$bit_rate" < "$framed_input" > "$framed_output" \
    2> "$client_log"; then
    :
else
    status=$?
    cat "$client_log" >&2
    exit "$status"
fi
cat "$client_log" >&2
frames="$(/usr/local/libexec/dawnshell-codec-ffmpeg.py unpack-annexb \
    "$framed_output" "$encoded" --require-keyframe)"
/usr/local/libexec/dawnshell-codec-ffmpeg.py validate-stats \
    "$client_log" "$frames"
case "$output" in
    *.h264|*.H264|*.264)
        cp -- "$encoded" "$output"
        ;;
    *)
        ffmpeg -hide_banner -loglevel error -y -r "$frame_rate" -f h264 \
            -i "$encoded" -map 0:v:0 -an -c:v copy "$output"
        ;;
esac
echo "DawnShell Surface transcode complete: frames=$frames output=$output"
EOF_CODEC_SURFACE_TRANSCODE
chmod 0755 /usr/local/bin/dawnshell-hwtranscode
chown 0:0 /usr/local/bin/dawnshell-hwtranscode

cat > /usr/local/bin/dawnshell-ffmpeg <<'EOF_CODEC_AUTO_FFMPEG'
#!/bin/bash
set -euo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Transparent front end for ordinary FFmpeg callers. Commands the DawnShell
# bridge can reproduce exactly run on the Android hardware codec. Everything
# else is handed to the real FFmpeg unchanged, so behaviour never silently
# differs from what the caller asked for.

real_ffmpeg=/usr/bin/ffmpeg
[ -x "$real_ffmpeg" ] || {
    echo "dawnshell-ffmpeg: /usr/bin/ffmpeg is missing; install ffmpeg" >&2
    exit 127
}

run_real_ffmpeg() {
    exec "$real_ffmpeg" "$@"
}

if [ "${DAWNSHELL_FFMPEG_BRIDGE:-auto}" = off ]; then
    run_real_ffmpeg "$@"
fi

plan="$(/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg "$@" 2>/dev/null || true)"
action="${plan%% *}"
action="${action#action=}"

field() {
    printf '%s\n' "$plan" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

case "$action" in
    decode|transcode) ;;
    *)
        if [ "${DAWNSHELL_FFMPEG_BRIDGE:-auto}" = require ]; then
            echo "dawnshell-ffmpeg: hardware bridge required but unavailable: ${plan:-no plan}" >&2
            exit 3
        fi
        run_real_ffmpeg "$@"
        ;;
esac

input="$(field input)"
output="$(field output)"
[ -n "$input" ] && [ -n "$output" ] || run_real_ffmpeg "$@"

if [ "$action" = decode ]; then
    exec /usr/local/bin/dawnshell-hwdecode "$input" "$output"
fi

codec="$(field codec)"
bitrate="$(field bitrate)"
if [ "$codec" != avc ]; then
    if [ "${DAWNSHELL_FFMPEG_BRIDGE:-auto}" = require ]; then
        echo "dawnshell-ffmpeg: Surface transcode only produces H.264" >&2
        exit 3
    fi
    run_real_ffmpeg "$@"
fi
exec /usr/local/bin/dawnshell-hwtranscode "$input" "$output" "${bitrate:-4000000}"
EOF_CODEC_AUTO_FFMPEG
chmod 0755 /usr/local/bin/dawnshell-ffmpeg
chown 0:0 /usr/local/bin/dawnshell-ffmpeg

install -d -m 0755 -o root -g root /usr/local/sbin
cat > /usr/local/sbin/reboot <<'EOF_HOST_REBOOT'
#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || {
    echo "reboot: root privileges are required" >&2
    exit 1
}

bridge=/run/dawnshell-host-reboot
if [ "${1-}" = "--check" ] && [ "$#" -eq 1 ]; then
    [ -p "$bridge" ] || {
        echo "reboot: Android host bridge is unavailable" >&2
        exit 1
    }
    echo "Android host reboot bridge ready"
    exit 0
fi

[ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = now ]; } || {
    echo "usage: reboot [now|--check]" >&2
    exit 2
}
[ -p "$bridge" ] || {
    echo "reboot: Android host bridge is unavailable" >&2
    exit 1
}
printf 'ANDROID_REBOOT\n' > "$bridge"
sleep 10
echo "reboot: Android host did not reboot within 10 seconds" >&2
exit 1
EOF_HOST_REBOOT
chmod 0755 /usr/local/sbin/reboot
chown 0:0 /usr/local/sbin/reboot

echo dawnshell > /etc/hostname
: > /etc/machine-id
systemd-machine-id-setup
mkdir -p /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

if ! getent passwd debian >/dev/null; then
    useradd --create-home --shell /bin/bash --user-group debian
fi
usermod --shell /bin/bash --password x debian
install -d -m 0700 -o debian -g debian /home/debian/.ssh

normalized=/run/dawnshell-authorized-keys.normalized
: > "$normalized"
key_count=0
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
        ''|'#'*) continue ;;
    esac
    case "$line" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
        *) echo "ERROR: authorized_keys contains an option or unsupported key type"; exit 32 ;;
    esac
    printf '%s\n' "$line" > /run/dawnshell-one-key
    ssh-keygen -l -f /run/dawnshell-one-key >/dev/null || {
        echo "ERROR: authorized_keys contains an invalid public key"
        exit 33
    }
    printf '%s\n' "$line" >> "$normalized"
    key_count=$((key_count + 1))
done < /run/dawnshell-authorized-keys
[ "$key_count" -gt 0 ] || { echo "ERROR: no SSH public keys were supplied"; exit 34; }
install -m 0600 -o debian -g debian "$normalized" /home/debian/.ssh/authorized_keys
rm -f /run/dawnshell-one-key "$normalized" /run/dawnshell-authorized-keys

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-dawnshell.conf <<'EOF_SSHD'
Port 22
AddressFamily inet
ListenAddress 0.0.0.0
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
PermitRootLogin no
UsePAM no
AllowUsers debian
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PrintMotd yes
EOF_SSHD

cat > /etc/motd <<'EOF_MOTD'
DawnShell Debian 13 emergency environment
Started during Direct Boot; remains active after Android unlock.
EOF_MOTD

ssh-keygen -A
# ssh.service creates this through RuntimeDirectory=sshd at normal boot. The
# AFU configurator validates sshd before systemd is running, and /run is a fresh
# private tmpfs for every configuration attempt, so create the directory here
# as well to keep reconfiguration idempotent.
install -d -m 0755 -o root -g root /run/sshd
sshd -t
effective="$(sshd -T -C user=debian,host=dawnshell,addr=127.0.0.1)"
grep -Fqx 'port 22' <<<"$effective"
grep -Fqx 'passwordauthentication no' <<<"$effective"
grep -Fqx 'kbdinteractiveauthentication no' <<<"$effective"
grep -Fqx 'permitrootlogin no' <<<"$effective"
grep -Fqx 'usepam no' <<<"$effective"
grep -Fqx 'authenticationmethods publickey' <<<"$effective"

mkdir -p /etc/systemd/system.conf.d /etc/systemd/journald.conf.d
cat > /etc/systemd/system.conf.d/10-dawnshell.conf <<'EOF_SYSTEMD'
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=20s
ShowStatus=yes
EOF_SYSTEMD
cat > /etc/systemd/journald.conf.d/10-dawnshell.conf <<'EOF_JOURNALD'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
ForwardToConsole=no
EOF_JOURNALD

cat > /etc/systemd/system/dawnshell-codec-long-run.service <<'EOF_CODEC_LONG_RUN_SERVICE'
[Unit]
Description=DawnShell hardware codec five-workload long-run regression
After=local-fs.target
ConditionPathExists=/usr/local/bin/dawnshell-codec-long-run

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dawnshell-codec-long-run all 600
TimeoutStartSec=90min
KillMode=control-group
StandardOutput=journal
StandardError=journal
EOF_CODEC_LONG_RUN_SERVICE
chmod 0644 /etc/systemd/system/dawnshell-codec-long-run.service

cat > /etc/systemd/system/dawnshell-boot-proof.service <<'EOF_BOOT_PROOF'
[Unit]
Description=DawnShell enabled-unit boot proof
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /run/dawnshell-enabled-service.ready
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_BOOT_PROOF

# These units either try to configure Android-owned kernel/network state or
# operate directly on bind-mounted host pseudo filesystems.
systemctl --root=/ --no-reload mask \
    systemd-remount-fs.service \
    systemd-fsck-root.service \
    'systemd-fsck@.service' \
    systemd-modules-load.service \
    systemd-sysctl.service \
    systemd-binfmt.service \
    systemd-timesyncd.service \
    systemd-networkd.service \
    systemd-networkd-wait-online.service \
    systemd-resolved.service \
    systemd-udevd.service \
    systemd-udev-trigger.service \
    systemd-udev-settle.service \
    console-getty.service \
    systemd-tmpfiles-setup-dev-early.service \
    systemd-tmpfiles-setup-dev.service \
    proc-sys-fs-binfmt_misc.automount \
    proc-sys-fs-binfmt_misc.mount \
    sys-kernel-debug.mount \
    sys-kernel-tracing.mount

: > /etc/fstab
systemctl --root=/ --no-reload enable \
    ssh.service dawnshell-boot-proof.service
systemctl --root=/ --no-reload set-default multi-user.target
[ "$(systemctl --root=/ is-enabled ssh.service)" = enabled ]
[ "$(systemctl --root=/ is-enabled dawnshell-boot-proof.service)" = enabled ]
[ -x /usr/local/sbin/reboot ]
[ -x /usr/local/bin/dawnshell-hwdecode ]
[ -x /usr/local/bin/dawnshell-hwencode ]
[ -x /usr/local/bin/dawnshell-hwtranscode ]
[ -x /usr/local/bin/dawnshell-ffmpeg ]
[ -x /usr/local/bin/dawnshell-codec-performance-test ]
[ -x /usr/local/bin/dawnshell-codec-long-run ]
[ -x /usr/local/bin/dawnshell-codec-concurrency-test ]
[ -x /usr/local/bin/dawnshell-codec-error-test ]

cat > "${READY_MARKER}.new" <<EOF_READY
format=1
suite=trixie
architecture=$DAWNSHELL_DEBIAN_ARCH
init=/sbin/init
ssh_service=ssh.service
boot_proof_service=dawnshell-boot-proof.service
ssh_user=debian
ssh_port=22
host_reboot_bridge=/usr/local/sbin/reboot
hardware_codec_client=/usr/local/bin/dawnshell-codec
hardware_codec_self_test=/usr/local/bin/dawnshell-codec-self-test
hardware_codec_performance_test=/usr/local/bin/dawnshell-codec-performance-test
hardware_codec_long_run_test=/usr/local/bin/dawnshell-codec-long-run
hardware_codec_concurrency_test=/usr/local/bin/dawnshell-codec-concurrency-test
hardware_codec_error_test=/usr/local/bin/dawnshell-codec-error-test
hardware_codec_decode=/usr/local/bin/dawnshell-hwdecode
hardware_codec_encode=/usr/local/bin/dawnshell-hwencode
hardware_codec_transcode=/usr/local/bin/dawnshell-hwtranscode
hardware_codec_ffmpeg=/usr/local/bin/dawnshell-ffmpeg
configured_epoch=$(date +%s)
EOF_READY
chown 0:0 "${READY_MARKER}.new"
chmod 0644 "${READY_MARKER}.new"
mv "${READY_MARKER}.new" "$READY_MARKER"
sync

echo "CONFIGURE_SUCCEEDED: Debian 13 systemd, enabled-unit proof, and public-key-only SSH are ready"
DEBIAN_CONFIG

sync
echo "CONFIGURE_SUCCEEDED: $ROOT is ready for BFU systemd PID 1 and SSH port $SSH_PORT user $SSH_USER"
