#!/system/bin/sh
set -eu

# Runs only after Android's first unlock. Termux CE binaries are management
# tools for this one AFU operation; Debian itself remains at /data/local/debian.

PREFIX=/data/data/com.termux/files/usr
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

[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || \
    fail 2 "usage: configure-debian-systemd.sh ROOT BFU_ROOT AUTHORIZED_KEYS [--inside-mount-ns]"

REQUESTED_ROOT="$1"
BFU_ROOT="$2"
AUTHORIZED_KEYS="$3"
MODE="${4-}"

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

if [ "$MODE" != "--inside-mount-ns" ]; then
    [ -x "$PREFIX/bin/unshare" ] || \
        fail 10 "missing $PREFIX/bin/unshare; run in Termux: pkg install util-linux mount-utils"
    [ -x "$PREFIX/bin/mount" ] || \
        fail 10 "missing $PREFIX/bin/mount; run in Termux: pkg install mount-utils"
    echo "Creating private AFU mount namespace for Debian configuration"
    exec "$PREFIX/bin/unshare" --mount --fork \
        /system/bin/sh "$0" "$ROOT" "$BFU_ROOT" "$AUTHORIZED_KEYS" \
        --inside-mount-ns
fi

umask 022
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export HOME="$BFU_ROOT/home"
export TMPDIR="$BFU_ROOT/tmp"
unset LD_PRELOAD || true

for tool in awk cat chroot chmod chown cp date grep id mkdir mount mv \
    readlink rm rmdir sed stat sync tr; do
    [ -x "$PREFIX/bin/$tool" ] || \
        fail 10 "missing $PREFIX/bin/$tool; run in Termux: pkg install util-linux mount-utils"
done

[ "$(id -u)" = "0" ] || fail 11 "configuration did not obtain uid 0"
[ "$(uname -m)" = "aarch64" ] || fail 12 "only aarch64 is supported"
[ -d "$ROOT" ] || fail 13 "rootfs is missing: $ROOT"
[ ! -L "$ROOT" ] || fail 13 "rootfs symlinks are forbidden"
[ "$(readlink -f "$ROOT")" = "$ROOT" ] || fail 13 "rootfs resolves elsewhere"
[ "$(stat -c '%u:%g' "$ROOT")" = "0:0" ] || fail 13 "rootfs is not root-owned"
[ -f "$ROOT/.termux-bfu-rootfs" ] || fail 14 "Termux BFU rootfs marker is missing"
grep -Fqx "suite=$SUITE" "$ROOT/.termux-bfu-rootfs" || \
    fail 14 "rootfs is not Debian 13 Trixie"
grep -Fqx 'architecture=arm64' "$ROOT/.termux-bfu-rootfs" || \
    fail 14 "rootfs is not arm64"
[ -x "$ROOT/bin/bash" ] || fail 15 "rootfs has no executable /bin/bash"
[ -f "$AUTHORIZED_KEYS" ] || fail 16 "save at least one SSH public key first"
[ ! -L "$AUTHORIZED_KEYS" ] || fail 16 "authorized_keys symlinks are forbidden"

key_size="$(stat -c '%s' "$AUTHORIZED_KEYS")"
case "$key_size" in
    ''|*[!0-9]*) fail 16 "could not determine authorized_keys size" ;;
esac
[ "$key_size" -gt 0 ] && [ "$key_size" -le 32768 ] || \
    fail 16 "authorized_keys must contain 1..32768 bytes"

echo "Making Android mounts recursively private"
mount --make-rprivate /

LOCK_DIR=/data/local/.termux-bfu-debian-config.lock
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

cp "$AUTHORIZED_KEYS" "$ROOT/run/termux-bfu-authorized-keys"
chmod 0600 "$ROOT/run/termux-bfu-authorized-keys"
chown 0:0 "$ROOT/run/termux-bfu-authorized-keys"

dns="$(getprop net.dns1 2>/dev/null || true)"
case "$dns" in
    ''|*[!0-9a-fA-F:.]*) dns=1.1.1.1 ;;
esac
printf 'nameserver %s\nnameserver 1.1.1.1\noptions timeout:2 attempts:3\n' "$dns" \
    > "$ROOT/etc/resolv.conf"
chmod 0644 "$ROOT/etc/resolv.conf"
chown 0:0 "$ROOT/etc/resolv.conf"

echo "Entering Debian 13 Trixie for systemd, D-Bus, and OpenSSH setup"
container=termux-bfu DEBIAN_FRONTEND=noninteractive \
    chroot "$ROOT" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    container=termux-bfu \
    DEBIAN_FRONTEND=noninteractive \
    /bin/bash -s <<'DEBIAN_CONFIG'
set -Eeuo pipefail

READY_MARKER=/.termux-bfu-systemd-ready
POLICY=/usr/sbin/policy-rc.d
POLICY_BACKUP=/run/termux-bfu-policy-rc.d.backup
POLICY_EXISTED=false

restore_policy() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$POLICY_EXISTED" = true ]; then
        rm -f "$POLICY"
        cp -a "$POLICY_BACKUP" "$POLICY"
    elif grep -Fq 'TERMUX_BFU_POLICY' "$POLICY" 2>/dev/null; then
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
[ "$(dpkg --print-architecture)" = arm64 ] || {
    echo "ERROR: expected Debian arm64"
    exit 31
}

if [ -e "$POLICY" ]; then
    cp -a "$POLICY" "$POLICY_BACKUP"
    POLICY_EXISTED=true
fi
cat > "$POLICY" <<'EOF_POLICY'
#!/bin/sh
# TERMUX_BFU_POLICY
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
    bash passwd mawk

cat > /etc/apt/sources.list <<'EOF_APT_HTTPS'
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://deb.debian.org/debian-security trixie-security main
EOF_APT_HTTPS
apt-get -o Acquire::Retries=3 update

for tool in /sbin/init /usr/bin/systemctl /usr/bin/journalctl /usr/bin/busctl \
    /usr/bin/timeout /usr/bin/ss /usr/bin/mawk /usr/bin/touch \
    /usr/sbin/shutdown; do
    [ -x "$tool" ] || {
        echo "ERROR: required BFU health tool is missing: $tool"
        exit 35
    }
done

echo termux-bfu > /etc/hostname
: > /etc/machine-id
systemd-machine-id-setup
mkdir -p /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

if ! getent passwd debian >/dev/null; then
    useradd --create-home --shell /bin/bash --user-group debian
fi
usermod --shell /bin/bash --password x debian
install -d -m 0700 -o debian -g debian /home/debian/.ssh

normalized=/run/termux-bfu-authorized-keys.normalized
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
    printf '%s\n' "$line" > /run/termux-bfu-one-key
    ssh-keygen -l -f /run/termux-bfu-one-key >/dev/null || {
        echo "ERROR: authorized_keys contains an invalid public key"
        exit 33
    }
    printf '%s\n' "$line" >> "$normalized"
    key_count=$((key_count + 1))
done < /run/termux-bfu-authorized-keys
[ "$key_count" -gt 0 ] || { echo "ERROR: no SSH public keys were supplied"; exit 34; }
install -m 0600 -o debian -g debian "$normalized" /home/debian/.ssh/authorized_keys
rm -f /run/termux-bfu-one-key "$normalized" /run/termux-bfu-authorized-keys

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-termux-bfu.conf <<'EOF_SSHD'
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
Termux BFU Debian 13 emergency environment
Started during Direct Boot; remains active after Android unlock.
EOF_MOTD

ssh-keygen -A
# ssh.service creates this through RuntimeDirectory=sshd at normal boot. The
# AFU configurator validates sshd before systemd is running, and /run is a fresh
# private tmpfs for every configuration attempt, so create the directory here
# as well to keep reconfiguration idempotent.
install -d -m 0755 -o root -g root /run/sshd
sshd -t
effective="$(sshd -T -C user=debian,host=termux-bfu,addr=127.0.0.1)"
grep -Fqx 'port 22' <<<"$effective"
grep -Fqx 'passwordauthentication no' <<<"$effective"
grep -Fqx 'kbdinteractiveauthentication no' <<<"$effective"
grep -Fqx 'permitrootlogin no' <<<"$effective"
grep -Fqx 'usepam no' <<<"$effective"
grep -Fqx 'authenticationmethods publickey' <<<"$effective"

mkdir -p /etc/systemd/system.conf.d /etc/systemd/journald.conf.d
cat > /etc/systemd/system.conf.d/10-termux-bfu.conf <<'EOF_SYSTEMD'
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=20s
ShowStatus=yes
EOF_SYSTEMD
cat > /etc/systemd/journald.conf.d/10-termux-bfu.conf <<'EOF_JOURNALD'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
ForwardToConsole=no
EOF_JOURNALD

cat > /etc/systemd/system/termux-bfu-boot-proof.service <<'EOF_BOOT_PROOF'
[Unit]
Description=Termux BFU enabled-unit boot proof
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /run/termux-bfu-enabled-service.ready
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
    ssh.service termux-bfu-boot-proof.service
systemctl --root=/ --no-reload set-default multi-user.target
[ "$(systemctl --root=/ is-enabled ssh.service)" = enabled ]
[ "$(systemctl --root=/ is-enabled termux-bfu-boot-proof.service)" = enabled ]

cat > "${READY_MARKER}.new" <<EOF_READY
format=1
suite=trixie
architecture=arm64
init=/sbin/init
ssh_service=ssh.service
boot_proof_service=termux-bfu-boot-proof.service
ssh_user=debian
ssh_port=22
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
