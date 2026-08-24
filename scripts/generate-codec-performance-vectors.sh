#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_dir/app/src/main/assets/bfu/codec-test"
temporary="$(mktemp -d)"
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT

for tool in ffmpeg sed sha256sum; do
  command -v "$tool" >/dev/null || {
    echo "Missing host tool: $tool" >&2
    exit 2
  }
done

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=1280x720:rate=30:duration=1' -frames:v 30 \
  -pix_fmt yuv420p -c:v libx264 -profile:v baseline -level:v 3.1 \
  -preset veryfast -crf 24 \
  -x264-params 'asm=0:threads=1:lookahead_threads=1:keyint=30:min-keyint=30:scenecut=0:bframes=0:aud=1:repeat-headers=1' \
  -an -f h264 "$temporary/avc-baseline-1280x720-30fps-30f.h264"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=1920x1080:rate=30:duration=2' -frames:v 60 \
  -pix_fmt yuv420p -c:v libx264 -profile:v high -level:v 4.0 \
  -preset veryfast -crf 26 \
  -x264-params 'asm=0:threads=1:lookahead_threads=1:keyint=60:min-keyint=60:scenecut=0:bframes=0:aud=1:repeat-headers=1' \
  -an -f h264 "$temporary/avc-high-1920x1080-30fps-60f.h264"

printf '%s  %s\n' \
  aa8cb11ff650c98d45b6975947024446e923cf055f3921189571bb8141d9c2a5 \
  "$temporary/avc-baseline-1280x720-30fps-30f.h264" \
  67ee26637911bb0ffc7b84749810b14cc7b3e35677f138be2c43448e33e1421b \
  "$temporary/avc-high-1920x1080-30fps-60f.h264" | sha256sum -c -

decoded_hash="$(ffmpeg -hide_banner -loglevel error -f h264 \
  -i "$temporary/avc-baseline-1280x720-30fps-30f.h264" \
  -map 0:v:0 -an -pix_fmt yuv420p -c:v rawvideo \
  -f hash -hash sha256 - | sed -n 's/^SHA256=//p')"
[[ "$decoded_hash" == \
  7ff494db80cf8a311468f9638384d3d7a7bd320b5b831110076b7c80979af26f ]] || {
  echo "Unexpected 720p software decode hash: $decoded_hash" >&2
  exit 1
}

if [[ "${1:-}" == "--write" ]]; then
  cp "$temporary/avc-baseline-1280x720-30fps-30f.h264" "$output_dir/"
  cp "$temporary/avc-high-1920x1080-30fps-60f.h264" "$output_dir/"
  echo "Updated committed performance vectors."
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--write]" >&2
  exit 2
else
  echo "Performance vectors reproduced with pinned SHA-256 values."
fi
