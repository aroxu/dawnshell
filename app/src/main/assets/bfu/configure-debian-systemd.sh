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
[ -f "$BFU_ROOT/downloads/avc-baseline-128x96-10fps.h264" ] || \
    fail 16 "hardware codec test vector is missing"
[ -f "$BFU_ROOT/downloads/avc-baseline-128x96-10fps.properties" ] || \
    fail 16 "hardware codec test metadata is missing"

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
    bash passwd mawk usbutils ffmpeg

cat > /etc/apt/sources.list <<'EOF_APT_HTTPS'
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://deb.debian.org/debian-security trixie-security main
EOF_APT_HTTPS
apt-get -o Acquire::Retries=3 update

for tool in /sbin/init /usr/bin/systemctl /usr/bin/journalctl /usr/bin/busctl \
    /usr/bin/timeout /usr/bin/ss /usr/bin/mawk /usr/bin/touch \
    /usr/bin/lsusb /usr/bin/ffmpeg /usr/bin/ffprobe /usr/sbin/shutdown; do
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
vector=/usr/local/share/dawnshell/avc-baseline-128x96-10fps.h264
expected=777feb39bd92b899fc9cf7c184396e3ecec4fdbcd7a582fc560fc37011f18053
temporary="$(mktemp /run/dawnshell-codec-i420.XXXXXX)"
encoded="$(mktemp /run/dawnshell-codec-h264.XXXXXX)"
cleanup() {
    rm -f "$temporary" "$encoded"
}
trap cleanup EXIT HUP INT TERM
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
EOF_CODEC_SELF_TEST
chmod 0755 /usr/local/bin/dawnshell-codec-self-test

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
