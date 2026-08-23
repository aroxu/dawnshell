#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 APK [OUTPUT_DIRECTORY]" >&2
    echo "Set DAWNSHELL_RELEASE_VERSION and optionally DAWNSHELL_SOURCE_REVISION." >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }

apk_input="$1"
output_dir="${2:-$repo_dir/dist/release}"
[[ -f "$apk_input" ]] || {
    echo "APK does not exist: $apk_input" >&2
    exit 2
}

version="${DAWNSHELL_RELEASE_VERSION:-}"
if [[ -z "$version" ]]; then
    version="$("$repo_dir/gradlew" -q -p "$repo_dir" :app:versionName)"
fi
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 2
fi

revision="${DAWNSHELL_SOURCE_REVISION:-$(git -C "$repo_dir" rev-parse HEAD)}"
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid source revision: $revision" >&2
    exit 2
fi
git -C "$repo_dir" cat-file -e "${revision}^{commit}"

dirty_source_entries=()
while IFS= read -r -d '' entry; do
    path="${entry:3}"
    case "$path" in
        app/src/main/assets/bfu/bin/*|\
        app/src/main/assets/bfu/bootstrap/debootstrap_1.0.141.tgz|\
        app/src/main/assets/bfu/bootstrap/debian-archive-keyring_2025.1_all.deb|\
        app/src/main/assets/bfu/bootstrap/SOURCES.lock)
            # Reproducible build outputs regenerated from the archived source.
            ;;
        *) dirty_source_entries+=("$entry") ;;
    esac
done < <(git -C "$repo_dir" status --porcelain=v1 -z --untracked-files=all)
if (( ${#dirty_source_entries[@]} > 0 )); then
    echo "Refusing to package a release from a dirty worktree." >&2
    echo "Commit every source, patch, configuration, license and script first." >&2
    printf '  %s\n' "${dirty_source_entries[@]}" >&2
    exit 3
fi

required_source_paths=(
    LICENSE
    LICENSES/README.md
    bfu-runtime/THIRD_PARTY_NOTICES.md
    bfu-runtime/config/busybox-bootstrap.config
    bfu-runtime/patches/busybox/0001-android-mount-without-addmntent.patch
    bfu-runtime/patches/libgpg-error/0001-skip-deprecated-config-self-test.patch
    bfu-runtime/sources/SOURCES.lock
    bfu-runtime/sources/busybox-1.38.0.tar.bz2
    bfu-runtime/sources/debian-archive-keyring_2025.1.dsc
    bfu-runtime/sources/debian-archive-keyring_2025.1.tar.xz
    scripts/build-bootstrap-runtime.sh
    scripts/package-release.sh
    app/build.gradle
    gradlew
    gradle/wrapper/gradle-wrapper.properties
)
for path in "${required_source_paths[@]}"; do
    git -C "$repo_dir" cat-file -e "$revision:$path" || {
        echo "Corresponding-source revision is missing: $path" >&2
        exit 4
    }
done

source_date_epoch="$(git -C "$repo_dir" show -s --format=%ct "$revision")"
short_revision="${revision:0:12}"
safe_version="${version//+/_}"
prefix="dawnshell-${safe_version}-${short_revision}"

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
apk_name="dawnshell-${safe_version}.apk"
source_name="${prefix}-corresponding-source.tar.gz"
licenses_name="${prefix}-licenses.tar.gz"
build_info_name="${prefix}-build-info.txt"
release_notes_name="RELEASE_NOTES.md"

cp "$apk_input" "$output_dir/$apk_name"

git -C "$repo_dir" archive --format=tar --prefix="$prefix/" "$revision" \
    | gzip -n -9 > "$output_dir/$source_name"

(
    cd "$repo_dir"
    tar --sort=name --mtime="@$source_date_epoch" \
        --owner=0 --group=0 --numeric-owner \
        -cf - LICENSES bfu-runtime/THIRD_PARTY_NOTICES.md
) | gzip -n -9 > "$output_dir/$licenses_name"

for path in "${required_source_paths[@]}"; do
    tar -tzf "$output_dir/$source_name" \
        | grep -Fx "$prefix/$path" >/dev/null || {
        echo "Generated source archive is missing: $path" >&2
        exit 4
    }
done

{
    printf 'DawnShell build information\n'
    printf 'version=%s\n' "$version"
    printf 'source_commit=%s\n' "$revision"
    printf 'source_commit_time=%s\n' "$source_date_epoch"
    printf 'android_package=me.aroxu.dawnshell\n'
    printf 'android_abis=armeabi-v7a,arm64-v8a,x86_64\n'
    printf 'android_ndk=29.0.14206865\n'
    printf 'corresponding_source=%s\n' "$source_name"
    printf 'license_bundle=%s\n' "$licenses_name"
} > "$output_dir/$build_info_name"

# Backticks below are literal Markdown delimiters, not shell substitutions.
# shellcheck disable=SC2016
{
    printf '# DawnShell %s\n\n' "$version"
    printf 'Built from commit [`%s`](https://github.com/aroxu/dawnshell/commit/%s).\n\n' \
        "$revision" "$revision"
    printf 'This release contains the installable APK, SHA-256 checksums, a separate '
    printf 'license bundle, and the complete corresponding source used to build the '
    printf 'bundled GPL/LGPL command-line programs.\n\n'
    printf -- '- APK: `%s`\n' "$apk_name"
    printf -- '- Corresponding source: `%s`\n' "$source_name"
    printf -- '- License bundle: `%s`\n' "$licenses_name"
    printf -- '- Build metadata: `%s`\n\n' "$build_info_name"
    printf 'DawnShell application code is MIT licensed. Bundled programs and libraries '
    printf 'retain the licenses identified in `THIRD_PARTY_NOTICES.md` and the attached '
    printf 'license bundle. The APK also exposes the same documents from its '
    printf '**Open-source licenses** screen.\n'
} > "$output_dir/$release_notes_name"

(
    cd "$output_dir"
    sha256sum \
        "$apk_name" "$source_name" "$licenses_name" \
        "$build_info_name" "$release_notes_name" > SHA256SUMS
    sha256sum -c SHA256SUMS
)

printf 'Release package created in %s\n' "$output_dir"
printf 'APK: %s\n' "$apk_name"
printf 'Source: %s\n' "$source_name"
printf 'Licenses: %s\n' "$licenses_name"
