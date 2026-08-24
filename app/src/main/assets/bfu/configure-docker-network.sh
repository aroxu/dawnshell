#!/system/bin/sh
set -eu

# AFU-only policy writer. It enters a private mount namespace, probes the
# Debian firewall frontends without changing rules, and publishes a managed
# daemon.json only when no unmanaged Docker configuration would be overwritten.

ROOT=/data/local/debian

fail() {
    code="$1"
    shift
    echo "ERROR: $*"
    exit "$code"
}

[ "$#" -eq 5 ] || [ "$#" -eq 6 ] || \
    fail 2 "usage: configure-docker-network.sh ROOT BFU_ROOT POLICY DEBIAN_ARCH HOST_IPC_COMPATIBILITY [--inside-mount-ns]"

REQUESTED_ROOT="$1"
BFU_ROOT="$2"
POLICY="$3"
EXPECTED_ARCH="$4"
HOST_IPC_COMPATIBILITY="$5"
MODE="${6-}"
BIN="$BFU_ROOT/bin"
TOOLBOX="$BIN/busybox"

[ "$REQUESTED_ROOT" = "$ROOT" ] || fail 3 "only $ROOT is allowed"
case "$BFU_ROOT" in
    /*) ;;
    *) fail 3 "BFU root must be absolute" ;;
esac
case "$BFU_ROOT" in
    /data/data/*|/data/user/*) fail 3 "BFU control files must use Device Protected Storage" ;;
esac
case "$POLICY" in
    host|auto|native_nft|iptables_nft|legacy) ;;
    *) fail 3 "Docker network policy must be host, auto, native_nft, iptables_nft, or legacy" ;;
esac
case "$EXPECTED_ARCH" in
    armhf|arm64|amd64) ;;
    *) fail 3 "unsupported Debian architecture: $EXPECTED_ARCH" ;;
esac
case "$HOST_IPC_COMPATIBILITY" in
    true|false) ;;
    *) fail 3 "Docker host IPC compatibility must be true or false" ;;
esac

if [ "$MODE" != "--inside-mount-ns" ]; then
    [ -x "$TOOLBOX" ] || fail 10 "source-built DawnShell toolbox is missing"
    echo "Creating private AFU mount namespace for Docker policy"
    exec "$TOOLBOX" unshare --mount --fork \
        /system/bin/sh "$0" "$ROOT" "$BFU_ROOT" "$POLICY" \
        "$EXPECTED_ARCH" "$HOST_IPC_COMPATIBILITY" --inside-mount-ns
fi

umask 022
export PATH="$BIN:/system/bin:/system/xbin"
export HOME="$BFU_ROOT/home"
export TMPDIR="$BFU_ROOT/tmp"
unset LD_PRELOAD || true

"$TOOLBOX" --install -s "$BIN" || \
    fail 10 "could not provision bootstrap toolbox applets"

for tool in cat chroot date grep id mkdir mount mv readlink rm rmdir \
    sha256sum stat sync tr; do
    command -v "$tool" >/dev/null 2>&1 || \
        fail 10 "source-built bootstrap applet is missing: $tool"
done

[ "$(id -u)" = 0 ] || fail 11 "Docker policy did not obtain uid 0"
[ -d "$ROOT" ] || fail 13 "rootfs is missing: $ROOT"
[ ! -L "$ROOT" ] || fail 13 "rootfs symlinks are forbidden"
RESOLVED_ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || \
    fail 13 "rootfs path could not be resolved"
[ "$RESOLVED_ROOT" = "$ROOT" ] || fail 13 "rootfs resolves elsewhere"
[ "$(stat -c '%u:%g' "$ROOT")" = "0:0" ] || fail 13 "rootfs is not root-owned"
[ -f "$ROOT/.dawnshell-rootfs" ] || fail 14 "DawnShell rootfs marker is missing"
grep -Fqx 'suite=trixie' "$ROOT/.dawnshell-rootfs" || \
    fail 14 "rootfs is not Debian 13 Trixie"
grep -Fqx "architecture=$EXPECTED_ARCH" "$ROOT/.dawnshell-rootfs" || \
    fail 14 "rootfs architecture does not match app runtime $EXPECTED_ARCH"

echo "Making Android mounts recursively private"
mount --make-rprivate /

LOCK_DIR=/data/local/.dawnshell-docker-policy.lock
LOCK_HELD=false
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$LOCK_HELD" = true ]; then
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR"
    fi
    [ "$result" -eq 0 ] || echo "DOCKER_POLICY_FAILED: exit=$result"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$LOCK_DIR" 2>/dev/null || fail 17 "another Docker policy operation is active"
LOCK_HELD=true
echo "$$" > "$LOCK_DIR/owner"

for directory in dev proc sys run; do
    [ -d "$ROOT/$directory" ] || fail 18 "missing rootfs directory: /$directory"
done

echo "Binding /dev and /sys; mounting private /proc and /run"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
mount --rbind /sys "$ROOT/sys"
mount --make-rslave "$ROOT/sys"
mount -t proc -o nosuid,nodev,noexec proc "$ROOT/proc"
mount -t tmpfs -o nosuid,nodev,mode=0755,size=32m tmpfs "$ROOT/run"
mkdir -p "$ROOT/run/lock"

echo "Entering Debian to negotiate Docker network compatibility"
DAWNSHELL_DOCKER_POLICY="$POLICY" \
DAWNSHELL_DOCKER_HOST_IPC="$HOST_IPC_COMPATIBILITY" container=dawnshell \
    chroot "$ROOT" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    container=dawnshell \
    DAWNSHELL_DOCKER_POLICY="$POLICY" \
    DAWNSHELL_DOCKER_HOST_IPC="$HOST_IPC_COMPATIBILITY" \
    /bin/bash -s <<'DEBIAN_POLICY'
set -Eeuo pipefail

policy="${DAWNSHELL_DOCKER_POLICY:?}"
host_ipc_compatibility="${DAWNSHELL_DOCKER_HOST_IPC:?}"
docker_dir=/etc/docker
daemon_json=$docker_dir/daemon.json
managed_hash=$docker_dir/.dawnshell-daemon-json.sha256
policy_record=/etc/dawnshell/docker-network-policy
docker_wrapper=/usr/local/bin/docker
docker_wrapper_hash=/etc/dawnshell/docker-wrapper.sha256

source /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || {
    echo "ERROR: expected Debian Trixie"
    exit 30
}
if command -v dockerd >/dev/null 2>&1; then
    echo "PROBE: dockerd is installed"
else
    echo "WARNING: dockerd is not installed yet; policy will apply on future installation"
fi
command -v sha256sum >/dev/null 2>&1 || {
    echo "ERROR: sha256sum is missing"
    exit 31
}

install -d -m 0755 -o root -g root "$docker_dir" /etc/dawnshell
if [ -s "$daemon_json" ]; then
    [ -f "$managed_hash" ] || {
        echo "ERROR: existing unmanaged /etc/docker/daemon.json was preserved; merge it manually"
        exit 32
    }
    expected="$(sed -n '1p' "$managed_hash")"
    actual="$(sha256sum "$daemon_json" | awk '{print $1}')"
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || {
        echo "ERROR: managed daemon.json was modified outside DawnShell; refusing to overwrite it"
        exit 32
    }
fi

verify_managed_wrapper() {
    [ -e "$docker_wrapper" ] || return 0
    [ -f "$docker_wrapper" ] && [ ! -L "$docker_wrapper" ] || {
        echo "ERROR: existing non-regular $docker_wrapper was preserved"
        exit 32
    }
    [ -f "$docker_wrapper_hash" ] || {
        echo "ERROR: existing unmanaged $docker_wrapper was preserved"
        exit 32
    }
    expected_wrapper_hash="$(sed -n '1p' "$docker_wrapper_hash")"
    actual_wrapper_hash="$(sha256sum "$docker_wrapper" | awk '{print $1}')"
    [ -n "$expected_wrapper_hash" ] \
        && [ "$actual_wrapper_hash" = "$expected_wrapper_hash" ] || {
        echo "ERROR: managed Docker wrapper was modified outside DawnShell; refusing to overwrite it"
        exit 32
    }
}

configure_host_ipc_wrapper() {
    verify_managed_wrapper
    if [ "$host_ipc_compatibility" = false ]; then
        rm -f "$docker_wrapper" "$docker_wrapper_hash"
        echo "POLICY: Docker host IPC compatibility wrapper disabled"
        return
    fi

    install -d -m 0755 -o root -g root /usr/local/bin
    wrapper_temporary="${docker_wrapper}.dawnshell.$$"
    cat > "$wrapper_temporary" <<'EOF_DOCKER_WRAPPER'
#!/bin/bash
set -e

real_docker=/usr/bin/docker
[ -x "$real_docker" ] || {
    echo "DawnShell: $real_docker is missing; install the Docker CLI" >&2
    exit 127
}

arguments=("$@")
command_index=-1
if (( ${#arguments[@]} > 0 )); then
    case "${arguments[0]}" in
        run|create) command_index=0 ;;
        container)
            if (( ${#arguments[@]} > 1 )); then
                case "${arguments[1]}" in
                    run|create) command_index=1 ;;
                esac
            fi
            ;;
    esac
fi

if (( command_index >= 0 )); then
    explicit_ipc=false
    for argument in "${arguments[@]}"; do
        case "$argument" in
            --ipc|--ipc=*) explicit_ipc=true ;;
        esac
    done
    if [ "$explicit_ipc" = false ]; then
        rewritten=("${arguments[@]:0:$((command_index + 1))}")
        rewritten+=(--ipc=host)
        rewritten+=("${arguments[@]:$((command_index + 1))}")
        exec "$real_docker" "${rewritten[@]}"
    fi
fi

exec "$real_docker" "${arguments[@]}"
EOF_DOCKER_WRAPPER
    chown 0:0 "$wrapper_temporary"
    chmod 0755 "$wrapper_temporary"
    new_wrapper_hash="$(sha256sum "$wrapper_temporary" | awk '{print $1}')"
    mv "$wrapper_temporary" "$docker_wrapper"
    printf '%s\n' "$new_wrapper_hash" > "$docker_wrapper_hash"
    chown 0:0 "$docker_wrapper_hash"
    chmod 0600 "$docker_wrapper_hash"
    echo "POLICY: Docker run/create wrapper enables --ipc=host by default"
    echo "WARNING: containers share Android/Debian host IPC; use /usr/bin/docker to bypass"
}

probe_iptables_check() {
    binary="$1"
    label="$2"
    shift 2
    set +e
    output="$("$binary" -w 1 "$@" 2>&1)"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        return 0
    fi
    case "$output" in
        *"Bad rule"*|*"does a matching rule exist"*)
            # -C is deliberately read-only. A missing exact rule proves that
            # the kernel parsed its match/target even though no rule matched.
            return 0
            ;;
    esac
    clean_output="$(printf '%s' "$output" | tr '\r\n' '  ')"
    echo "PROBE: $label rejected status=$status output=$clean_output"
    return 1
}

probe_iptables_backend() {
    binary="$1"
    [ -x "$binary" ] || return 1
    "$binary" -w 1 -t nat -S >/dev/null 2>&1 || return 1
    probe_iptables_check "$binary" addrtype \
        -t nat -C PREROUTING -m addrtype --dst-type LOCAL -j ACCEPT || return 1
    probe_iptables_check "$binary" masquerade \
        -t nat -C POSTROUTING -j MASQUERADE || return 1
    probe_iptables_check "$binary" conntrack \
        -t filter -C FORWARD -m conntrack \
        --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
}

probe_native_nft() {
    command -v dockerd >/dev/null 2>&1 || return 1
    command -v nft >/dev/null 2>&1 || return 1
    dockerd --help 2>&1 | grep -q -- '--firewall-backend' || return 1
    nft list ruleset >/dev/null 2>&1 || return 1
    probe_config=/run/dawnshell-docker-native-nft-probe.json
    cat > "$probe_config" <<'EOF_NATIVE_PROBE'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "bridge": "none",
  "firewall-backend": "nftables",
  "iptables": false,
  "ip6tables": false
}
EOF_NATIVE_PROBE
    if dockerd --validate --config-file "$probe_config" >/dev/null 2>&1; then
        result=0
    else
        result=1
    fi
    rm -f "$probe_config"
    return "$result"
}

backend=none
case "$policy" in
    host)
        echo "POLICY: safe host-network-only mode; no firewall backend probe needed"
        ;;
    auto)
        echo "PROBE: trying native Docker nftables first"
        if probe_native_nft; then
            backend=native-nft
        else
            echo "PROBE: native nftables unavailable; trying iptables-nft"
            if probe_iptables_backend /usr/sbin/iptables-nft; then
                backend=iptables-nft
            else
                echo "PROBE: iptables-nft unavailable or incompatible; trying iptables-legacy"
                if probe_iptables_backend /usr/sbin/iptables-legacy; then
                    backend=legacy
                else
                    echo "WARNING: no bridge firewall backend has Docker's required addrtype, masquerade, and conntrack capabilities"
                    echo "FALLBACK: using safe host-network-only mode"
                    backend=none
                fi
            fi
        fi
        ;;
    native_nft)
        echo "PROBE: forcing native Docker nftables"
        probe_native_nft || {
            echo "ERROR: forced native nftables requires Docker 29+, dockerd config validation, and a working nft ruleset query"
            exit 33
        }
        backend=native-nft
        ;;
    iptables_nft)
        echo "PROBE: forcing iptables-nft"
        probe_iptables_backend /usr/sbin/iptables-nft || {
            echo "ERROR: forced iptables-nft frontend is unavailable or incompatible"
            exit 33
        }
        backend=iptables-nft
        ;;
    legacy)
        echo "PROBE: forcing iptables-legacy"
        probe_iptables_backend /usr/sbin/iptables-legacy || {
            echo "ERROR: forced legacy frontend is unavailable or incompatible"
            exit 33
        }
        backend=legacy
        ;;
esac

case "$backend" in
  iptables-nft|legacy)
    suffix="$backend"
    [ "$backend" = iptables-nft ] && suffix=nft
    iptables_binary="/usr/sbin/iptables-$suffix"
    ip6tables_binary="/usr/sbin/ip6tables-$suffix"
    update-alternatives --set iptables "$iptables_binary"
    if [ -x "$ip6tables_binary" ]; then
        update-alternatives --set ip6tables "$ip6tables_binary"
    fi
    ;;
esac
[ "$backend" = none ] || \
    echo "WARNING: bridge mode can mutate Android-global firewall, NAT, routes, and forwarding"

temporary="$docker_dir/.daemon.json.dawnshell.$$"
# Some kernels panic in copy_ipcs()->mq_init_ns()->mqueue_mount() when a new
# IPC namespace is created, so every container shares the host IPC
# namespace. The CLI wrapper only covers `docker run` and `docker create`;
# setting the daemon default also protects `docker compose`, the API, and any
# other client. A container can still opt out with an explicit --ipc value.
if [ "$host_ipc_compatibility" = true ]; then
    ipc_mode_entry='  "default-ipc-mode": "host",'
else
    ipc_mode_entry=''
fi
if [ "$backend" = none ]; then
    cat > "$temporary" <<EOF_HOST
{
${ipc_mode_entry:+$ipc_mode_entry
}  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "bridge": "none",
  "iptables": false,
  "ip6tables": false,
  "ip-forward": false,
  "ip-masq": false,
  "userland-proxy": false
}
EOF_HOST
elif [ "$backend" = native-nft ]; then
    cat > "$temporary" <<EOF_NATIVE_NFT
{
${ipc_mode_entry:+$ipc_mode_entry
}  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "firewall-backend": "nftables",
  "iptables": true,
  "ip6tables": false,
  "ip-forward": true,
  "ip-masq": true,
  "userland-proxy": true
}
EOF_NATIVE_NFT
else
    cat > "$temporary" <<EOF_BRIDGE
{
${ipc_mode_entry:+$ipc_mode_entry
}  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "iptables": true,
  "ip6tables": false,
  "ip-forward": true,
  "ip-masq": true,
  "userland-proxy": true
}
EOF_BRIDGE
fi
chown 0:0 "$temporary"
chmod 0644 "$temporary"
if command -v dockerd >/dev/null 2>&1 \
        && dockerd --help 2>&1 | grep -q -- '--validate'; then
    dockerd --validate --config-file "$temporary" || {
        rm -f "$temporary"
        echo "ERROR: dockerd rejected the generated managed configuration"
        exit 34
    }
fi
new_hash="$(sha256sum "$temporary" | awk '{print $1}')"
mv "$temporary" "$daemon_json"
printf '%s\n' "$new_hash" > "$managed_hash"
chown 0:0 "$managed_hash"
chmod 0600 "$managed_hash"

configure_host_ipc_wrapper

cat > "${policy_record}.new" <<EOF_RECORD
format=2
requested_policy=$policy
resolved_backend=$backend
network_namespace=android-shared
cgroup_driver=cgroupfs
host_ipc_compatibility=$host_ipc_compatibility
docker_cli_wrapper=$([ "$host_ipc_compatibility" = true ] && echo /usr/local/bin/docker || echo none)
bridge_mutates_android_global_netfilter=$([ "$backend" = none ] && echo false || echo true)
configured_epoch=$(date +%s)
EOF_RECORD
chown 0:0 "${policy_record}.new"
chmod 0644 "${policy_record}.new"
mv "${policy_record}.new" "$policy_record"
sync

echo "DOCKER_POLICY_SUCCEEDED: requested=$policy resolved_backend=$backend cgroup_driver=cgroupfs host_ipc_compatibility=$host_ipc_compatibility"
if [ "$backend" = none ]; then
    echo "USAGE: start containers with --network host"
fi
DEBIAN_POLICY

sync
echo "DOCKER_POLICY_SUCCEEDED: requested=$POLICY"
