#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk_path="${1:-}"

required_licenses=(
    README.md
    ANDROID_DEPENDENCIES.md
    DawnShell-MIT.txt
    Apache-2.0.txt
    CC0-1.0.txt
    Expat.txt
    GPL-2.0-only.txt
    GPL-2.0-or-later.txt
    GPL-3.0-or-later.txt
    LGPL-2.1-or-later.txt
    LGPL-3.0-or-later.txt
    base-installer-1.226-copyright.txt
    debian-archive-keyring-2025.1-copyright.txt
    GnuPG-2.4.9-additional-notices.txt
    Libgcrypt-1.12.1-additional-notices.txt
)

for name in "${required_licenses[@]}"; do
    [[ -s "$repo_dir/LICENSES/$name" ]] || {
        echo "Missing license document: LICENSES/$name" >&2
        exit 10
    }
done

[[ -s "$repo_dir/bfu-runtime/THIRD_PARTY_NOTICES.md" ]]

while read -r hash filename url license extra; do
    [[ -n "$hash" && "${hash:0:1}" != '#' ]] || continue
    [[ -z "${extra:-}" ]] || {
        echo "Malformed SOURCES.lock line for $filename" >&2
        exit 11
    }
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]]
    [[ "$url" =~ ^https:// ]]
    [[ -n "$license" ]]
    printf '%s  %s\n' "$hash" "$repo_dir/bfu-runtime/sources/$filename" \
        | sha256sum -c -
done < "$repo_dir/bfu-runtime/sources/SOURCES.lock"

cmp -s "$repo_dir/bfu-runtime/sources/SOURCES.lock" \
    "$repo_dir/app/src/main/assets/bfu/bootstrap/SOURCES.lock" || {
    echo "Packaged SOURCES.lock does not match the corresponding-source lock" >&2
    exit 11
}
printf '%s  %s\n' \
    232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b \
    "$repo_dir/app/src/main/assets/bfu/bootstrap/debootstrap_1.0.141.tgz" \
    | sha256sum -c -
printf '%s  %s\n' \
    9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac \
    "$repo_dir/app/src/main/assets/bfu/bootstrap/debian-archive-keyring_2025.1_all.deb" \
    | sha256sum -c -

grep -Fq 'debian-archive-keyring_2025.1.tar.xz' \
    "$repo_dir/bfu-runtime/sources/debian-archive-keyring_2025.1.dsc"
grep -Fq 'Android libraries' "$repo_dir/bfu-runtime/THIRD_PARTY_NOTICES.md"
grep -Fq 'corresponding source' "$repo_dir/LICENSES/README.md"
grep -Fxq 'CONFIG_STAT=y' \
    "$repo_dir/bfu-runtime/config/busybox-bootstrap.config"
grep -Fxq 'CONFIG_FEATURE_STAT_FORMAT=y' \
    "$repo_dir/bfu-runtime/config/busybox-bootstrap.config"
grep -Fq "stat -c '%u:%g' \"\$TOOLBOX\"" \
    "$repo_dir/app/src/main/assets/bfu/install-debian-rootfs.sh"

bash -n "$repo_dir/scripts/build-bootstrap-runtime.sh"
bash -n "$repo_dir/scripts/package-release.sh"

if [[ -n "$apk_path" ]]; then
    [[ -f "$apk_path" ]] || {
        echo "APK does not exist: $apk_path" >&2
        exit 12
    }
    if command -v unzip >/dev/null 2>&1; then
        apk_list() { unzip -Z1 "$apk_path"; }
        apk_read() { unzip -p "$apk_path" "$1"; }
    elif command -v bsdtar >/dev/null 2>&1; then
        apk_list() { bsdtar -tf "$apk_path"; }
        apk_read() { bsdtar -xOf "$apk_path" "$1"; }
    else
        echo "unzip or bsdtar is required to inspect the APK" >&2
        exit 12
    fi
    revision="${DAWNSHELL_SOURCE_REVISION:-$(git -C "$repo_dir" rev-parse HEAD)}"
    for name in "${required_licenses[@]}"; do
        apk_list \
            | grep -Fx "assets/open_source_licenses/$name" >/dev/null || {
            echo "APK is missing license asset: $name" >&2
            exit 13
        }
    done
    for name in THIRD_PARTY_NOTICES.md SOURCE_OFFER.txt; do
        apk_list \
            | grep -Fx "assets/open_source_licenses/$name" >/dev/null || {
            echo "APK is missing license asset: $name" >&2
            exit 13
        }
    done
    apk_read assets/open_source_licenses/SOURCE_OFFER.txt \
        | grep -F "$revision" >/dev/null || {
        echo "APK source offer does not identify source revision $revision" >&2
        exit 14
    }
fi

echo "Release compliance checks passed."
