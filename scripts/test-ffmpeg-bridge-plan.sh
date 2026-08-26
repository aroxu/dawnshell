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

# Upstream MediaCodec spellings must reach the bridge unchanged.
expect_plan 'action=encode input=in.mp4 output=out.mp4 codec=avc bitrate=4000000 explicit=mediacodec' \
    -i in.mp4 -c:v h264_mediacodec -b:v 4M out.mp4
expect_plan 'action=encode input=in.mp4 output=out.mp4 codec=avc audio=copy explicit=mediacodec' \
    -y -i in.mp4 -c:a copy -c:v h264_mediacodec out.mp4
expect_plan 'action=encode input=in.mp4 output=out.mp4 codec=hevc explicit=mediacodec' \
    -i in.mp4 -c:v hevc_mediacodec out.mp4
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc bitrate=6000000 explicit=mediacodec' \
    -hwaccel mediacodec -i in.mp4 -c:v h264_mediacodec -b:v 6M out.mp4
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc explicit=mediacodec' \
    -hwaccel mediacodec -i in.mp4 -c:v libx264 out.mp4
expect_plan 'action=decode input=in.mp4 output=out.yuv explicit=mediacodec' \
    -hwaccel mediacodec -i in.mp4 out.yuv
# A hardware decoder named before -i selects the decoder, not the encoder.
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc explicit=mediacodec' \
    -c:v h264_mediacodec -i in.mp4 -c:v libx264 out.mp4
# Software decoders and neutral -hwaccel values stay supported.
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc' \
    -c:v h264 -i in.mp4 -c:v libx264 out.mp4
expect_plan 'action=transcode input=in.mp4 output=out.mp4 codec=avc' \
    -hwaccel auto -i in.mp4 -c:v libx264 out.mp4

# Anything the bridge cannot reproduce exactly must stay on plain FFmpeg.
expect_passthrough -i in.mp4 -vf scale=640:480 -c:v libx264 out.mp4
expect_passthrough -hwaccel cuda -i in.mp4 -c:v libx264 out.mp4
expect_passthrough -c:v vp9 -i in.webm -c:v libx264 out.mp4
# An unsupported request still reports that hardware was named explicitly.
expect_plan 'action=passthrough reason=unsupported_option explicit=mediacodec' \
    -i in.mp4 -vf scale=2:2 -c:v h264_mediacodec out.mp4
expect_passthrough -i in.mp4 -c:v copy out.mp4
expect_passthrough -i a.mp4 -i b.mp4 -c:v libx264 out.mp4
expect_passthrough -i in.mp4 -c:v libvpx-vp9 out.webm
expect_passthrough -i in.mp4 -c:v libx264 -crf 23 out.mp4
expect_passthrough -i in.mp4 -c:v libx264 -preset slow out.mp4
expect_plan 'action=passthrough reason=unsupported_audio_codec explicit=mediacodec' \
    -i in.mp4 -c:a aac -c:v h264_mediacodec out.mp4
expect_plan 'action=passthrough reason=audio_copy_requires_bytebuffer_encode explicit=mediacodec' \
    -hwaccel mediacodec -i in.mp4 -c:a copy -c:v h264_mediacodec out.mp4
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

# The wrapper must own the plain "ffmpeg" name by default, and the integration
# must stay reversible without touching Debian's packaged binary.
grep -Fq 'ln -sfn /usr/local/bin/dawnshell-ffmpeg /usr/local/bin/ffmpeg.new' \
    "$wrapper_source"
grep -Fq 'cat > /usr/local/bin/dawnshell-ffmpeg-integration' "$wrapper_source"
grep -Fq 'hardware_codec_ffmpeg_integration=enabled' "$wrapper_source"
if grep -Eq 'rm +-f +/usr/bin/ffmpeg|mv .*/usr/bin/ffmpeg' "$wrapper_source"; then
    echo "FAIL: the configurator must never modify Debian's packaged ffmpeg" >&2
    exit 1
fi

integration_dir="$(mktemp -d)"
trap 'rm -rf -- "$wrapper_dir" "$integration_dir"' EXIT
python3 - "$wrapper_source" "$integration_dir/integration" <<'PYTHON_EXTRACT_INTEGRATION'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
opening = ("cat > /usr/local/bin/dawnshell-ffmpeg-integration "
           "<<'EOF_FFMPEG_INTEGRATION'\n")
begin = source.index(opening) + len(opening)
end = source.index("\nEOF_FFMPEG_INTEGRATION\n", begin)
pathlib.Path(sys.argv[2]).write_text(source[begin:end] + "\n", encoding="utf-8")
PYTHON_EXTRACT_INTEGRATION
sh -n "$integration_dir/integration"

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

# Generated Debian tools run from systemd and root shells with a minimal
# environment, so each one must set its own PATH instead of inheriting it.
# A missing PATH previously surfaced as "install: not found".
generated_scripts="$(grep -c '^export LC_ALL=C$' "$wrapper_source")"
generated_paths="$(grep -c '^export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$' \
    "$wrapper_source")"
if [[ "$generated_scripts" -lt 1 || "$generated_scripts" != "$generated_paths" ]]; then
    echo "FAIL: $generated_scripts generated tools but $generated_paths declare PATH" >&2
    exit 1
fi
python3 - "$wrapper_source" <<'PYTHON_VERIFY_PATH'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
for match in re.finditer(r"cat > (/usr/local/(?:bin|sbin)/[\w.-]+) <<'(\w+)'\n", source):
    name, marker = match.group(1), match.group(2)
    body = source[match.end():source.index("\n" + marker + "\n", match.end())]
    if "install " not in body and "mktemp" not in body:
        continue
    if expected not in body:
        raise SystemExit(f"{name} uses install/mktemp without declaring PATH")
print("generated Debian tools declare an explicit PATH")
PYTHON_VERIFY_PATH

stub_dir="$wrapper_dir/stubs"
mkdir -p "$stub_dir"
for stub in ffmpeg dawnshell-hwdecode dawnshell-hwencode dawnshell-hwtranscode; do
    printf '#!/bin/sh\necho "STUB %s $*"\n' "$stub" > "$stub_dir/$stub"
    chmod 0755 "$stub_dir/$stub"
done
runnable="$wrapper_dir/runnable"
# The generated wrapper pins a minimal PATH, so the stub harness must reach
# its interpreter and the adapter by absolute path.
python_binary="$(command -v python3)"
sed -e "s#^real_ffmpeg=.*#real_ffmpeg=$stub_dir/ffmpeg#" \
    -e "s#/usr/local/libexec/dawnshell-codec-ffmpeg.py#$python_binary $adapter#g" \
    -e "s#/usr/local/bin/dawnshell-hwdecode#$stub_dir/dawnshell-hwdecode#g" \
    -e "s#/usr/local/bin/dawnshell-hwencode#$stub_dir/dawnshell-hwencode#g" \
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

# Upstream MediaCodec spellings must execute on hardware end to end.
expect_run "STUB dawnshell-hwencode in.mp4 out.mp4 4000000 avc" \
    -i in.mp4 -c:v h264_mediacodec out.mp4
expect_run "STUB dawnshell-hwencode in.mp4 out.mp4 2500000 hevc" \
    -i in.mp4 -c:v hevc_mediacodec -b:v 2500k out.mp4
expect_run "STUB dawnshell-hwencode in.mp4 out.mp4 4000000 avc copy" \
    -y -i in.mp4 -c:a copy -c:v h264_mediacodec out.mp4
expect_run "STUB dawnshell-hwtranscode in.mp4 out.mp4 6000000" \
    -hwaccel mediacodec -i in.mp4 -c:v h264_mediacodec -b:v 6M out.mp4
expect_run "STUB dawnshell-hwdecode in.mp4 out.yuv" \
    -hwaccel mediacodec -i in.mp4 out.yuv

expect_run "STUB ffmpeg -i in.mp4 -vf scale=640:480 -c:v libx264 out.mp4" \
    -i in.mp4 -vf scale=640:480 -c:v libx264 out.mp4
expect_run "STUB ffmpeg -i in.mp4 -c:v copy out.mp4" -i in.mp4 -c:v copy out.mp4
# HEVC output has no Surface encoder path yet, so it must fall back.
expect_run "STUB ffmpeg -i in.mp4 -c:v libx265 out.mp4" \
    -i in.mp4 -c:v libx265 out.mp4

DAWNSHELL_FFMPEG_BRIDGE=off expect_run \
    "STUB ffmpeg -i in.mp4 -c:v libx264 out.mp4" -i in.mp4 -c:v libx264 out.mp4
# Explicit MediaCodec must obey an explicit off switch.
DAWNSHELL_FFMPEG_BRIDGE=off expect_run \
    "STUB ffmpeg -i in.mp4 -c:v h264_mediacodec out.mp4" \
    -i in.mp4 -c:v h264_mediacodec out.mp4
# Naming MediaCodec must fail loudly instead of falling back silently.
if "$runnable" -i in.mp4 -vf scale=2:2 -c:v h264_mediacodec out.mp4 \
        >/dev/null 2>&1; then
    echo "FAIL: explicit mediacodec fell back to software" >&2
    exit 1
fi
if DAWNSHELL_FFMPEG_BRIDGE=require "$runnable" \
        -i in.mp4 -vf scale=2:2 -c:v libx264 out.mp4 >/dev/null 2>&1; then
    echo "FAIL: require mode accepted an unsupported command" >&2
    exit 1
fi

# Every script the build pipeline invokes must stay executable in Git; a
# non-executable mode fails CI with exit code 126 instead of a real error.
while IFS= read -r pipeline_script; do
    mode="$(git -C "$repo_dir" ls-files -s -- "$pipeline_script" | cut -d' ' -f1)"
    if [[ -n "$mode" && "$mode" != 100755 ]]; then
        echo "FAIL: $pipeline_script is committed as $mode; run git update-index --chmod=+x" >&2
        exit 1
    fi
done < <(grep -ho 'scripts/[a-z0-9-]*\.sh' \
    "$repo_dir/.github/workflows/build.yml" "$repo_dir/scripts/build-all.sh" \
    | sort -u)

echo "PASS: FFmpeg bridge routes supported commands to hardware and falls back otherwise."
