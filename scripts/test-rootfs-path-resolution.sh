#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system_configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
docker_configurator="$repo_dir/app/src/main/assets/bfu/configure-docker-network.sh"
remover="$repo_dir/app/src/main/java/me/aroxu/dawnshell/DebianRootfsRemover.java"

for script in "$system_configurator" "$docker_configurator"; do
    grep -Fq 'RESOLVED_ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd -P)"' "$script"
    grep -Fq '[ "$RESOLVED_ROOT" = "$ROOT" ] || fail 13 "rootfs resolves elsewhere"' "$script"
    if grep -Eq 'readlink[[:space:]]+-f' "$script"; then
        echo "Unsupported BusyBox readlink -f remains in $script" >&2
        exit 1
    fi
done

grep -Fq 'resolved=$(cd -P \"$root\" 2>/dev/null && pwd -P) || exit 42;' "$remover"
if grep -Eq 'readlink[[:space:]]+-f' "$remover"; then
    echo "Unsupported Android readlink -f remains in $remover" >&2
    exit 1
fi

echo "Rootfs path resolution policy checks passed"
