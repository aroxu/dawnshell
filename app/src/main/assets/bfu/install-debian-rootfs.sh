#!/system/bin/sh
set -eu

# This installer uses only the ABI-specific toolbox provisioned in Device
# Protected Storage. It never reads Termux or another app's CE storage.

TARGET=/data/local/debian
STAGE=/data/local/debian.installing
# BusyBox TLS does not authenticate peers, so package transport is HTTP. Debian
# Release signatures and every Packages/.deb hash are still verified by gpgv.
MIRROR=http://deb.debian.org/debian
SUITE=trixie
DEBOOTSTRAP_VERSION=1.0.141
ARCHIVE_KEYRING_VERSION=2025.1
DEBOOTSTRAP_SHA256=232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b
KEYRING_SHA256=9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac

fail() {
    code="$1"
    shift
    echo "ERROR: $*"
    exit "$code"
}

[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || \
    fail 2 "usage: install-debian-rootfs.sh DEBOOTSTRAP_ARCHIVE KEYRING_DEB BFU_ROOT DEBIAN_ARCH [--inside-mount-ns]"

DEBOOTSTRAP_ARCHIVE="$1"
KEYRING_DEB="$2"
BFU_ROOT="$3"
DEBIAN_ARCH="$4"
MODE="${5-}"
BIN="$BFU_ROOT/bin"
TOOLBOX="$BIN/busybox"
GPGV="$BIN/gpgv"
PKGDETAILS_BINARY="$BIN/pkgdetails"

case "$BFU_ROOT" in
    /*) ;;
    *) fail 3 "BFU root must be an absolute path" ;;
esac
case "$BFU_ROOT" in
    /data/data/*|/data/user/*)
        fail 3 "BFU control files must not be in Credential Encrypted storage"
        ;;
esac
case "$DEBOOTSTRAP_ARCHIVE" in
    "$BFU_ROOT"/downloads/*) ;;
    *) fail 3 "debootstrap archive is outside the provisioned BFU download directory" ;;
esac
case "$KEYRING_DEB" in
    "$BFU_ROOT"/downloads/*) ;;
    *) fail 3 "archive keyring package is outside the provisioned BFU download directory" ;;
esac
case "$DEBIAN_ARCH" in
    armhf|arm64|amd64) ;;
    *) fail 3 "unsupported Debian architecture: $DEBIAN_ARCH" ;;
esac

if [ "$MODE" != "--inside-mount-ns" ]; then
    [ -x "$TOOLBOX" ] || fail 10 "source-built DawnShell toolbox is missing"
    echo "Creating private mount namespace for rootfs installation"
    exec "$TOOLBOX" unshare --mount --fork \
        /system/bin/sh "$0" "$DEBOOTSTRAP_ARCHIVE" "$KEYRING_DEB" \
        "$BFU_ROOT" "$DEBIAN_ARCH" --inside-mount-ns
fi

umask 022
export PATH="$BIN:/system/bin:/system/xbin"
export HOME="$BFU_ROOT/home"
export TMPDIR="$BFU_ROOT/tmp"
unset LD_PRELOAD || true

for tool in "$TOOLBOX" "$GPGV" "$PKGDETAILS_BINARY"; do
    [ -x "$tool" ] || fail 10 "missing source-built bootstrap executable: $tool"
done

# Populate private applet symlinks from the source-built BusyBox multicall
# binary. The operation is idempotent and remains entirely inside BFU DE.
"$TOOLBOX" --install -s "$BIN" || \
    fail 10 "could not provision bootstrap toolbox applets"

for tool in awk cat chroot chmod cp cut date df dpkg-deb grep gzip head id \
    mkdir mknod mount mv rm rmdir sed sha256sum stat sync tail tar tr umount \
    uname wget; do
    command -v "$tool" >/dev/null 2>&1 || \
        fail 10 "source-built bootstrap applet is missing: $tool"
done

[ "$(id -u)" = "0" ] || fail 11 "installer did not obtain uid 0"
[ -r "$DEBOOTSTRAP_ARCHIVE" ] || fail 13 "debootstrap source archive is missing"
[ -r "$KEYRING_DEB" ] || fail 14 "Debian archive keyring package is missing"

echo "Making Android mounts recursively private inside the installer namespace"
mount --make-rprivate /

LOCK_DIR=/data/local/.dawnshell-debian-install.lock
WORK=""
LOCK_HELD=false

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
    if [ "$LOCK_HELD" = true ]; then
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR"
    fi
    if [ "$result" -ne 0 ]; then
        echo "INSTALL_FAILED: exit=$result"
        if [ -d "$STAGE" ]; then
            echo "Partial rootfs preserved for diagnosis at $STAGE"
        fi
        if [ -s "$STAGE/debootstrap/debootstrap.log" ]; then
            echo "DEBOOTSTRAP_LOG_TAIL_BEGIN"
            tail -n 120 "$STAGE/debootstrap/debootstrap.log"
            echo "DEBOOTSTRAP_LOG_TAIL_END"
        fi
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
        *install-debian-rootfs.sh*)
            fail 15 "another rootfs installer is active as host pid $old_pid"
            ;;
    esac

    stale_lock="${LOCK_DIR}.stale.$(date +%s)"
    suffix=0
    while [ -e "$stale_lock" ]; do
        suffix=$((suffix + 1))
        stale_lock="${LOCK_DIR}.stale.$(date +%s).$suffix"
    done
    echo "Preserving stale installer lock as $stale_lock"
    mv "$LOCK_DIR" "$stale_lock"
    mkdir "$LOCK_DIR" || fail 16 "could not acquire installer lock"
fi
LOCK_HELD=true
echo "$$" > "$LOCK_DIR/owner"

if [ -d "$TARGET" ]; then
    if [ -f "$TARGET/.dawnshell-rootfs" ] && \
       [ -x "$TARGET/bin/sh" ] && [ -s "$TARGET/etc/debian_version" ]; then
        if grep -Fqx "suite=$SUITE" "$TARGET/.dawnshell-rootfs" && \
           grep -Fqx "architecture=$DEBIAN_ARCH" "$TARGET/.dawnshell-rootfs"; then
            echo "ALREADY_INSTALLED: verified Debian 13 Trixie rootfs exists at $TARGET; no files changed"
            exit 0
        fi
        fail 20 "$TARGET contains a different verified DawnShell rootfs; expected suite=$SUITE architecture=$DEBIAN_ARCH; refusing to overwrite or upgrade it"
    fi
    fail 20 "$TARGET already exists but is not a verified DawnShell rootfs; refusing to overwrite it"
fi

if [ -e "$TARGET" ]; then
    fail 21 "$TARGET exists and is not a directory; refusing to overwrite it"
fi

if [ -e "$STAGE" ]; then
    preserved="/data/local/debian.failed.$(date +%s)"
    suffix=0
    while [ -e "$preserved" ]; do
        suffix=$((suffix + 1))
        preserved="/data/local/debian.failed.$(date +%s).$suffix"
    done
    echo "Preserving stale staging tree as $preserved"
    mv "$STAGE" "$preserved"
fi

available_kb="$(df -Pk /data/local | awk 'END { print $4 }')"
case "$available_kb" in
    ''|*[!0-9]*) echo "WARNING: could not determine free space under /data/local" ;;
    *)
        echo "Free space under /data/local: ${available_kb} KiB"
        [ "$available_kb" -ge 524288 ] || \
            fail 22 "at least 512 MiB free is required for the bootstrap"
        ;;
esac

echo "Rechecking pinned artifact checksums as uid 0"
printf '%s  %s\n' "$DEBOOTSTRAP_SHA256" "$DEBOOTSTRAP_ARCHIVE" | sha256sum -c -
printf '%s  %s\n' "$KEYRING_SHA256" "$KEYRING_DEB" | sha256sum -c -

WORK="$BFU_ROOT/tmp/debootstrap.$$"
case "$WORK" in
    "$BFU_ROOT"/tmp/debootstrap.*) ;;
    *) fail 23 "unsafe temporary work path" ;;
esac
mkdir -p "$WORK/source" "$WORK/keyring"

echo "Extracting verified Debian Trixie debootstrap $DEBOOTSTRAP_VERSION"
tar -xzf "$DEBOOTSTRAP_ARCHIVE" -C "$WORK/source"
echo "Extracting verified Debian Trixie archive keyring $ARCHIVE_KEYRING_VERSION"
dpkg-deb -x "$KEYRING_DEB" "$WORK/keyring"

SOURCE_ROOT="$WORK/source/debootstrap"
KEYRING="$WORK/keyring/usr/share/keyrings/debian-archive-keyring.gpg"
RUNNER="$WORK/debootstrap-portable"
[ -s "$SOURCE_ROOT/debootstrap" ] || fail 24 "upstream debootstrap script was not extracted"
[ -s "$SOURCE_ROOT/functions" ] || fail 25 "upstream debootstrap functions were not extracted"
[ -s "$KEYRING" ] || fail 26 "Debian archive keyring was not extracted"

# --arch supplies the target and this file supplies the matching host ABI,
# avoiding debootstrap's optional dependency on a host dpkg installation.
printf '%s\n' "$DEBIAN_ARCH" > "$SOURCE_ROOT/arch"
cp "$PKGDETAILS_BINARY" "$SOURCE_ROOT/pkgdetails"
chmod 700 "$SOURCE_ROOT/pkgdetails"

# Keep host chroot resolution on the source-built BFU toolbox even while
# upstream temporarily assigns the target's PATH to an eval builtin.
# The replacement is intentionally literal.
# shellcheck disable=SC2016
sed 's|CHROOT_CMD="chroot \\"$TARGET\\""|CHROOT_CMD="$DAWNSHELL_HOST_CHROOT \\"$TARGET\\""|' \
    "$SOURCE_ROOT/debootstrap" > "$RUNNER"
chmod 700 "$RUNNER"
# Verify the literal code written above.
# shellcheck disable=SC2016
grep -Fq 'CHROOT_CMD="$DAWNSHELL_HOST_CHROOT \"$TARGET\""' "$RUNNER" || \
    fail 27 "the Android host-chroot portability patch was not applied"
export DAWNSHELL_HOST_CHROOT="$BIN/chroot"

# Upstream temporarily assigns the target PATH to the special shell builtin
# `eval` in in_target(). A POSIX shell may retain that assignment in the parent,
# so later host helpers could escape the source-built BFU PATH. Scope it to a
# subshell while preserving upstream diagnostics.
cat >> "$SOURCE_ROOT/functions" <<'EOF'

# DAWNSHELL_ANDROID_PATH_SCOPE
bfu_in_target () {
    (
        PATH=/sbin:/usr/sbin:/bin:/usr/bin
        export PATH
        eval "$CHROOT_CMD \"\$@\""
    )
}

in_target_nofail () {
    if ! bfu_in_target "$@" 2>/dev/null; then
        true
    fi
    return 0
}

in_target_failmsg () {
    local code msg arg
    code="$1"
    msg="$2"
    arg="$3"
    shift; shift; shift
    if ! bfu_in_target "$@"; then
        warning "$code" "$msg" "$arg"
        # Try to point the user at the actual failing package, matching
        # upstream debootstrap's in_target_failmsg implementation.
        msg="See %s for details"
        if [ -e "$TARGET/debootstrap/debootstrap.log" ]; then
            arg="$TARGET/debootstrap/debootstrap.log"
            local pkg
            pkg="$(grep '^dpkg: error processing ' "$TARGET/debootstrap/debootstrap.log" | head -n 1 | sed 's/\(error processing \)\(package \|archive \)/\1/' | cut -d ' ' -f 4)"
            if [ -n "$pkg" ]; then
                msg="$msg (possibly the package $pkg is at fault)"
            fi
        else
            arg="the log"
        fi
        warning "$code" "$msg" "$arg"
        return 1
    fi
    return 0
}
EOF
grep -Fq 'DAWNSHELL_ANDROID_PATH_SCOPE' "$SOURCE_ROOT/functions" || \
    fail 28 "the Android host-PATH compatibility patch was not applied"

mkdir -p "$STAGE"

WGETRC="$WORK/wgetrc"
cat > "$WGETRC" <<'EOF'
timeout = 60
read_timeout = 60
tries = 3
retry_connrefused = on
EOF
export WGETRC

echo "Starting Debian 13 Trixie $DEBIAN_ARCH minbase bootstrap"
echo "Target: $STAGE"
echo "Mirror: $MIRROR"
DEBOOTSTRAP_DIR="$SOURCE_ROOT" PKGDETAILS="$SOURCE_ROOT/pkgdetails" \
    "$TOOLBOX" ash "$RUNNER" \
    --arch="$DEBIAN_ARCH" \
    --extractor=ar \
    --variant=minbase \
    --keyring="$KEYRING" \
    --force-check-sig \
    --verbose \
    "$SUITE" "$STAGE" "$MIRROR"

echo "Validating completed rootfs"
[ -x "$STAGE/bin/sh" ] || fail 30 "completed tree has no executable /bin/sh"
[ -s "$STAGE/etc/debian_version" ] || fail 31 "completed tree has no Debian version"
[ -s "$STAGE/var/lib/dpkg/status" ] || fail 32 "completed tree has no dpkg status database"

debian_version="$(cat "$STAGE/etc/debian_version")"
case "$debian_version" in
    13|13.*) ;;
    *) fail 35 "unexpected Debian version: $debian_version" ;;
esac
[ -s "$STAGE/etc/os-release" ] || fail 36 "completed tree has no os-release metadata"
grep -Fqx 'VERSION_CODENAME=trixie' "$STAGE/etc/os-release" || \
    fail 37 "completed tree is not Debian Trixie"

rootfs_arch="$(chroot "$STAGE" /usr/bin/dpkg --print-architecture)"
[ "$rootfs_arch" = "$DEBIAN_ARCH" ] || fail 33 "unexpected rootfs architecture: $rootfs_arch"
passwd_owner="$(stat -c '%u:%g' "$STAGE/etc/passwd")"
[ "$passwd_owner" = "0:0" ] || fail 34 "root ownership was not preserved: /etc/passwd=$passwd_owner"

cat > "$STAGE/.dawnshell-rootfs" <<EOF
format=1
suite=$SUITE
architecture=$DEBIAN_ARCH
mirror=$MIRROR
debootstrap=$DEBOOTSTRAP_VERSION
archive_keyring=$ARCHIVE_KEYRING_VERSION
installed_epoch=$(date +%s)
EOF
chmod 644 "$STAGE/.dawnshell-rootfs"
sync

echo "Promoting completed staging tree to $TARGET"
mv "$STAGE" "$TARGET"
sync
echo "INSTALL_SUCCEEDED: Debian 13 Trixie rootfs ready at $TARGET"
