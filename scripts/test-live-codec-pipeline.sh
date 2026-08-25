#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adapter="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-ffmpeg.py"
live_encoder="$repo_dir/app/src/main/assets/bfu/dawnshell-live-encode.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

python3 - "$temporary/i420.raw" <<'PYTHON_RAW'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(bytes(range(256)) * 3)
PYTHON_RAW

python3 "$adapter" pack-i420 - 16 16 30/1 - \
    < "$temporary/i420.raw" \
    > "$temporary/i420.records" 2> "$temporary/pack.log"
grep -Fq 'packed_i420_frames=2' "$temporary/pack.log"
python3 - "$temporary/i420.records" <<'PYTHON_RECORDS'
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
record = struct.Struct(">QII")
offset = 0
expected_pts = [0, 33333]
for index, pts in enumerate(expected_pts):
    actual_pts, flags, size = record.unpack_from(data, offset)
    assert actual_pts == pts, (index, actual_pts)
    assert flags == 0
    assert size == 384
    offset += record.size + size
assert offset == len(data)
PYTHON_RECORDS

python3 - "$temporary/encoded.records" <<'PYTHON_ENCODED'
import pathlib
import struct
import sys

record = struct.Struct(">QII")
config = b"\x00\x00\x00\x01\x67\x64"
frame = b"\x00\x00\x00\x01\x65\x88"
payload = (
    record.pack(0, 2, len(config)) + config
    + record.pack(0, 1, len(frame)) + frame
    + record.pack(0, 4, 0)
)
pathlib.Path(sys.argv[1]).write_bytes(payload)
PYTHON_ENCODED

python3 "$adapter" unpack-annexb - - --require-keyframe \
    < "$temporary/encoded.records" \
    > "$temporary/output.h264" 2> "$temporary/unpack.log"
grep -Fq 'unpacked_annexb_frames=1' "$temporary/unpack.log"
python3 - "$temporary/output.h264" <<'PYTHON_ANNEXB'
import pathlib
import sys

assert pathlib.Path(sys.argv[1]).read_bytes() == (
    b"\x00\x00\x00\x01\x67\x64\x00\x00\x00\x01\x65\x88"
)
PYTHON_ANNEXB

bash "$live_encoder" --print-plan \
    --input /dev/video0 --input-format v4l2 --input-pixel-format mjpeg \
    --size 1280x720 --fps 30 --bitrate 4000000 \
    --output "$temporary/live/index.m3u8" --output-mode hls \
    --record "$temporary/live/recording.mp4" > "$temporary/plan.log"
grep -Fq 'stage=1 capture_to_i420' "$temporary/plan.log"
grep -Fq 'stage=3_android_mediacodec_avc_encode' "$temporary/plan.log"
grep -Fq 'dawnshell-codec pipe encode avc 1280 720 30 4000000' \
    "$temporary/plan.log"
grep -Fq 'hls_time=2' "$temporary/plan.log"
grep -Fq 'recording.mp4' "$temporary/plan.log"

if bash "$live_encoder" --input x --size 1279x720 --fps 30 --output out.mp4 \
        > /dev/null 2>&1; then
    echo "odd dimensions were accepted" >&2
    exit 1
fi

echo "PASS: live I420 framing, Annex-B streaming, and HLS/record plans"
