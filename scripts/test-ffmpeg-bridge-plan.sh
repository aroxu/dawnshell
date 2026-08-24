#!/usr/bin/env bash
# Pins the transparent FFmpeg front end: which command lines run on the
# Android hardware codec and which fall back to plain FFmpeg.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
adapter="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-ffmpeg.py"
wrapper_source="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
test -f "$adapter"

plan() {
    python3 "$adapter" plan-ffmpeg "$@"
}

expect_plan() {
    local expected="$1"
    shift
    local actual
    actual="$(plan "$@")"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: ffmpeg $*" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

expect_passthrough() {
    local actual
    actual="$(plan "$@")"
    if [[ "$actual" != action=passthrough* ]]; then
        echo "FAIL: expected software passthrough for: ffmpeg $*" >&2
        echo "  actual: $actual" >&2
        exit 1
    fi
}

# Hardware paths.
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc bitrate=3000000' \
    -i in.mp4 -c:v libx264 -b:v 3M out.mp4
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc bitrate=800000' \
    -hide_banner -y -i in.mp4 -map 0:v:0 -an -c:v libx264 -b:v 800k out.mp4
expect_plan 'action=transcode input=in.mkv output=out.mp4 codec=hevc' \
    -i in.mkv -c:v libx265 out.mp4
expect_plan 'action=decode input=in.mp4 output=out.yuv' -i in.mp4 out.yuv
expect_plan 'action=decode input=in.mp4 output=frames.i420' -i in.mp4 frames.i420

# Anything the bridge cannot reproduce exactly must stay on plain FFmpeg.
expect_passthrough -i in.mp4 -vf scale=640:480 -c:v libx264 out.mp4
expect_passthrough -i in.mp4 -c:v copy out.mp4
expect_passthrough -i a.mp4 -i b.mp4 -c:v libx264 out.mp4
expect_passthrough -i in.mp4 -c:v libvpx-vp9 out.webm
expect_passthrough -i in.mp4 -c:v libx264 -crf 23 out.mp4
expect_passthrough -i in.mp4 -c:v libx264 -preset slow out.mp4
expect_passthrough -i in.mp4 -map 0:a:0 -c:v libx264 out.mp4
expect_passthrough -i in.mp4 out.mp4
expect_passthrough -i in.mp4 -c:v libx264 -b:v 999 out.mp4
expect_passthrough -i in.mp4 -c:v libx264 -b:v abc out.mp4
expect_passthrough -c:v libx264 out.mp4
expect_passthrough -i in.mp4 -c:v libx264
expect_passthrough -i in.mp4 -c:v libx264 one.mp4 two.mp4

# The installed wrapper must delegate instead of reimplementing FFmpeg.
grep -Fq 'cat > /usr/local/bin/dawnshell-ffmpeg' "$wrapper_source"
grep -Fq 'real_ffmpeg=/usr/bin/ffmpeg' "$wrapper_source"
grep -Fq 'plan-ffmpeg' "$wrapper_source"
grep -Fq 'DAWNSHELL_FFMPEG_BRIDGE' "$wrapper_source"
grep -Fq '[ -x /usr/local/bin/dawnshell-ffmpeg ]' "$wrapper_source"
grep -Fq 'hardware_codec_ffmpeg=/usr/local/bin/dawnshell-ffmpeg' "$wrapper_source"

# The generated wrapper must itself be valid shell and must delegate for real.
wrapper_dir="$(mktemp -d)"
trap 'rm -rf -- "$wrapper_dir"' EXIT
python3 - "$wrapper_source" "$wrapper_dir/dawnshell-ffmpeg" <<'PYTHON_EXTRACT_WRAPPER'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
opening = "cat > /usr/local/bin/dawnshell-ffmpeg <<'EOF_CODEC_AUTO_FFMPEG'\n"
begin = source.index(opening) + len(opening)
end = source.index("\nEOF_CODEC_AUTO_FFMPEG\n", begin)
pathlib.Path(sys.argv[2]).write_text(source[begin:end] + "\n", encoding="utf-8")
PYTHON_EXTRACT_WRAPPER
bash -n "$wrapper_dir/dawnshell-ffmpeg"

stub_dir="$wrapper_dir/stubs"
mkdir -p "$stub_dir"
for stub in ffmpeg dawnshell-hwdecode dawnshell-hwtranscode; do
    printf '#!/bin/sh\necho "STUB %s $*"\n' "$stub" > "$stub_dir/$stub"
    chmod 0755 "$stub_dir/$stub"
done
runnable="$wrapper_dir/runnable"
sed -e "s#^real_ffmpeg=.*#real_ffmpeg=$stub_dir/ffmpeg#" \
    -e "s#/usr/local/libexec/dawnshell-codec-ffmpeg.py#python3 $adapter#g" \
    -e "s#/usr/local/bin/dawnshell-hwdecode#$stub_dir/dawnshell-hwdecode#g" \
    -e "s#/usr/local/bin/dawnshell-hwtranscode#$stub_dir/dawnshell-hwtranscode#g" \
    "$wrapper_dir/dawnshell-ffmpeg" > "$runnable"
chmod 0755 "$runnable"

expect_run() {
    local expected="$1"
    shift
    local actual
    actual="$("$runnable" "$@")"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: dawnshell-ffmpeg $*" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

expect_run "STUB dawnshell-hwtranscode in.mp4 out.mp4 3000000" \
    -i in.mp4 -c:v libx264 -b:v 3M out.mp4
expect_run "STUB dawnshell-hwtranscode in.mp4 out.mp4 4000000" \
    -i in.mp4 -c:v libx264 out.mp4
expect_run "STUB dawnshell-hwdecode in.mp4 out.yuv" -i in.mp4 out.yuv
expect_run "STUB ffmpeg -i in.mp4 -vf scale=640:480 -c:v libx264 out.mp4" \
    -i in.mp4 -vf scale=640:480 -c:v libx264 out.mp4
expect_run "STUB ffmpeg -i in.mp4 -c:v copy out.mp4" -i in.mp4 -c:v copy out.mp4
# HEVC output has no Surface encoder path yet, so it must fall back.
expect_run "STUB ffmpeg -i in.mp4 -c:v libx265 out.mp4" \
    -i in.mp4 -c:v libx265 out.mp4

DAWNSHELL_FFMPEG_BRIDGE=off expect_run \
    "STUB ffmpeg -i in.mp4 -c:v libx264 out.mp4" -i in.mp4 -c:v libx264 out.mp4
if DAWNSHELL_FFMPEG_BRIDGE=require "$runnable" \
        -i in.mp4 -vf scale=2:2 -c:v libx264 out.mp4 >/dev/null 2>&1; then
    echo "FAIL: require mode accepted an unsupported command" >&2
    exit 1
fi

echo "PASS: FFmpeg bridge routes supported commands to hardware and falls back otherwise."
