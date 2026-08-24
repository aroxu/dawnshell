#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_dir/app/src/main/assets/bfu/codec-test"
temporary="$(mktemp -d)"
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT

for tool in ffmpeg ffprobe sed sha256sum; do
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

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=1280x720:rate=30:duration=1' -frames:v 30 \
  -pix_fmt yuv420p -c:v libx264 -profile:v high -level:v 3.1 \
  -preset veryfast -crf 24 \
  -x264-params 'asm=0:threads=1:lookahead_threads=1:keyint=30:min-keyint=30:scenecut=0:bframes=2:aud=1:repeat-headers=1' \
  -an -fflags +bitexact -flags:v +bitexact -movflags +faststart \
  "$temporary/avc-high-1280x720-30fps-30f-b2.mp4"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=1920x1080:rate=30:duration=2' -frames:v 60 \
  -pix_fmt yuv420p -c:v libx265 -profile:v main -level:v 4.0 \
  -preset veryfast -crf 28 \
  -x265-params 'asm=0:pools=none:frame-threads=1:wpp=0:keyint=60:min-keyint=60:scenecut=0:bframes=0:aud=1:repeat-headers=1:log-level=error' \
  -an -fflags +bitexact -flags:v +bitexact -movflags +faststart \
  "$temporary/hevc-main-1920x1080-30fps-60f.mp4"

printf '%s  %s\n' \
  aa8cb11ff650c98d45b6975947024446e923cf055f3921189571bb8141d9c2a5 \
  "$temporary/avc-baseline-1280x720-30fps-30f.h264" \
  67ee26637911bb0ffc7b84749810b14cc7b3e35677f138be2c43448e33e1421b \
  "$temporary/avc-high-1920x1080-30fps-60f.h264" \
  1c88cf9b08d0527d83768171389d5bcc2a43075ace06b183fdfdcef3a633e57a \
  "$temporary/avc-high-1280x720-30fps-30f-b2.mp4" \
  2c6dae5d20ad02ddf08485440c888c361f4080df535c1803e3c74fd51259c8b2 \
  "$temporary/hevc-main-1920x1080-30fps-60f.mp4" | sha256sum -c -

decoded_hash="$(ffmpeg -hide_banner -loglevel error -f h264 \
  -i "$temporary/avc-baseline-1280x720-30fps-30f.h264" \
  -map 0:v:0 -an -pix_fmt yuv420p -c:v rawvideo \
  -f hash -hash sha256 - | sed -n 's/^SHA256=//p')"
[[ "$decoded_hash" == \
  7ff494db80cf8a311468f9638384d3d7a7bd320b5b831110076b7c80979af26f ]] || {
  echo "Unexpected 720p software decode hash: $decoded_hash" >&2
  exit 1
}

decoded_1080_hash="$(ffmpeg -hide_banner -loglevel error -f h264 \
  -i "$temporary/avc-high-1920x1080-30fps-60f.h264" \
  -map 0:v:0 -an -pix_fmt yuv420p -c:v rawvideo \
  -f hash -hash sha256 - | sed -n 's/^SHA256=//p')"
[[ "$decoded_1080_hash" == \
  48630f45fa17f58a0435ff0cdb18e42ae466a449cd5d7f7ba966f277b2c8082e ]] || {
  echo "Unexpected 1080p AVC software decode hash: $decoded_1080_hash" >&2
  exit 1
}

bframe_decoded_hash="$(ffmpeg -hide_banner -loglevel error \
  -i "$temporary/avc-high-1280x720-30fps-30f-b2.mp4" \
  -map 0:v:0 -an -pix_fmt yuv420p -c:v rawvideo \
  -f hash -hash sha256 - | sed -n 's/^SHA256=//p')"
[[ "$bframe_decoded_hash" == \
  484b59dce2d3a1ce58d0712583309f0a1ad8b0e0506ab226fb95191ef67cf437 ]] || {
  echo "Unexpected B-frame AVC software decode hash: $bframe_decoded_hash" >&2
  exit 1
}

hevc_decoded_hash="$(ffmpeg -hide_banner -loglevel error \
  -i "$temporary/hevc-main-1920x1080-30fps-60f.mp4" \
  -map 0:v:0 -an -pix_fmt yuv420p -c:v rawvideo \
  -f hash -hash sha256 - | sed -n 's/^SHA256=//p')"
[[ "$hevc_decoded_hash" == \
  a452cd360b635349b47f5c918364cef7e601735dbddbd94d50c435da74bf01d0 ]] || {
  echo "Unexpected HEVC software decode hash: $hevc_decoded_hash" >&2
  exit 1
}

b_frames="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=has_b_frames -of default=nw=1:nk=1 \
  "$temporary/avc-high-1280x720-30fps-30f-b2.mp4")"
[[ "$b_frames" == 2 ]] || {
  echo "Expected two AVC B-frame reorder slots; got $b_frames" >&2
  exit 1
}

hevc_codec="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name -of default=nw=1:nk=1 \
  "$temporary/hevc-main-1920x1080-30fps-60f.mp4")"
[[ "$hevc_codec" == hevc ]] || {
  echo "Expected HEVC test vector; got $hevc_codec" >&2
  exit 1
}

if [[ "${1:-}" == "--write" ]]; then
  cp "$temporary/avc-baseline-1280x720-30fps-30f.h264" "$output_dir/"
  cp "$temporary/avc-high-1920x1080-30fps-60f.h264" "$output_dir/"
  cp "$temporary/avc-high-1280x720-30fps-30f-b2.mp4" "$output_dir/"
  cp "$temporary/hevc-main-1920x1080-30fps-60f.mp4" "$output_dir/"
  echo "Updated committed performance vectors."
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--write]" >&2
  exit 2
else
  echo "Performance vectors reproduced with pinned SHA-256 values."
fi
