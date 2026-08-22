#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
output_dir="$repo_dir/app/src/main/assets/bfu/bin"
output_file="$output_dir/bfu-namespace-probe-arm64"

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK 29.0.14206865}"

case "$(uname -s)" in
    Linux*) host_tag=linux-x86_64 ;;
    Darwin*) host_tag=darwin-x86_64 ;;
    MINGW*|MSYS*|CYGWIN*) host_tag=windows-x86_64 ;;
    *) echo "Unsupported build host: $(uname -s)" >&2; exit 2 ;;
esac

toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag"
compiler="$toolchain/bin/aarch64-linux-android21-clang"
readelf="$toolchain/bin/llvm-readelf"
strip="$toolchain/bin/llvm-strip"
strings_tool="$toolchain/bin/llvm-strings"

[[ -x "$compiler" || -x "$compiler.cmd" ]] || {
    echo "Missing NDK compiler: $compiler" >&2
    exit 3
}
mkdir -p "$output_dir"

if grep -Eq 'unshare[[:space:]]*\([[:space:]]*CLONE_NEWIPC' "$source_file"; then
    echo "Unsafe CLONE_NEWIPC call is forbidden on the Samsung 4.4 target" >&2
    exit 6
fi

"$compiler" \
    -std=c17 -Os -fPIE -fstack-protector-strong \
    -Wall -Wextra -Werror -Wformat=2 \
    -Wl,-pie -Wl,-z,relro,-z,now -Wl,--gc-sections \
    "$source_file" -o "$output_file"
"$strip" --strip-unneeded "$output_file"

"$readelf" -h "$output_file" | grep -Eq 'Machine:[[:space:]]+AArch64'
"$readelf" -l "$output_file" | grep -Fq '/system/bin/linker64'
if "$readelf" -d "$output_file" | grep -F 'Shared library:' \
        | grep -Ev '\[(libc|libdl)\.so\]' >/dev/null; then
    echo "Unexpected native dependency:" >&2
    "$readelf" -d "$output_file" | grep -F 'Shared library:' >&2
    exit 4
fi
if "$strings_tool" "$output_file" \
        | grep -Eq '/data/data/com\.termux|/data/user(_de)?/[0-9]'; then
    echo "Credential Encrypted path embedded in BFU helper" >&2
    exit 5
fi

sha256sum "$output_file"
