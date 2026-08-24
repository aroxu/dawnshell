#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [ "${DAWNSHELL_CODEC_TEST_LOCK_HELD:-0}" != 1 ]; then
    install -d -m 0700 -o root -g root /var/lib/dawnshell
    exec 9> /var/lib/dawnshell/codec-test.lock
    /usr/bin/flock -n 9 || {
        echo "Another DawnShell hardware codec test is already running" >&2
        exit 75
    }
    export DAWNSHELL_CODEC_TEST_LOCK_HELD=1
fi

adapter=/usr/local/libexec/dawnshell-codec-ffmpeg.py
vector=/usr/local/share/dawnshell/avc-baseline-1280x720-30fps-30f.h264
hevc_vector=/usr/local/share/dawnshell/hevc-main-1920x1080-30fps-60f.mp4
result_root="${DAWNSHELL_CODEC_RESULT_DIR:-/var/log/dawnshell/codec-tests}"
install -d -m 0700 -o root -g root "$result_root"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-errors-$$"
result_dir="$result_root/$run_id"
install -d -m 0700 -o root -g root "$result_dir"
temporary="$(mktemp -d /run/dawnshell-codec-errors.XXXXXX)"
cleanup() {
    case "$temporary" in
        /run/dawnshell-codec-errors.*) rm -rf -- "$temporary" ;;
    esac
}
trap cleanup EXIT HUP INT TERM
log="$result_dir/operations.log"
before="$temporary/health-before.json"
after="$temporary/health-after.json"

ffprobe -v error -select_streams v:0 -show_packets \
    -show_entries packet=pts_time,dts_time -of json "$hevc_vector" \
    > "$temporary/hevc-input-packets.json"
ffmpeg -hide_banner -loglevel error -y -i "$hevc_vector" -map 0:v:0 -an \
    -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$temporary/input.hevc"
ffprobe -v error -f hevc -show_packets -show_entries packet=pos,size \
    -of json "$temporary/input.hevc" > "$temporary/hevc-raw-packets.json"
"$adapter" pack "$temporary/hevc-input-packets.json" \
    "$temporary/hevc-raw-packets.json" "$temporary/input.hevc" 30/1 \
    "$temporary/hevc.records" > "$temporary/hevc-pack.log"

python3 - "$vector" "$temporary" "$temporary/hevc.records" <<'PY_ERROR_VECTORS'
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1]).read_bytes()
target = pathlib.Path(sys.argv[2])
hevc_records = pathlib.Path(sys.argv[3])
record = struct.Struct(">QII")

def aud_positions(data):
    result = []
    index = 0
    while index + 5 < len(data):
        prefix = 0
        if data[index:index + 3] == b"\x00\x00\x01":
            prefix = 3
        elif data[index:index + 4] == b"\x00\x00\x00\x01":
            prefix = 4
        if prefix and data[index + prefix] & 0x1f == 9:
            result.append(index)
        index += prefix + 1 if prefix else 1
    return result

positions = aud_positions(source)
if len(positions) != 30:
    raise SystemExit(f"expected 30 AVC access units, got {len(positions)}")
positions.append(len(source))
units = [source[positions[i]:positions[i + 1]] for i in range(30)]

def write_records(name, values):
    with (target / name).open("wb") as output:
        for index, value in enumerate(values):
            output.write(record.pack(index * 1_000_000 // 30, 0, len(value)))
            output.write(value)

write_records("missing-config.records", units[1:])
write_records("truncated-bitstream.records", [units[0][:max(8, len(units[0]) // 3)]])
damaged = list(units)
middle = bytearray(damaged[10])
for index in range(len(middle) // 3, min(len(middle), len(middle) // 3 + 32)):
    middle[index] ^= 0x5a
damaged[10] = bytes(middle)
write_records("damaged.records", damaged)

unsupported_profile = bytearray(units[0])
index = 0
profile_mutated = False
while index + 8 < len(unsupported_profile):
    prefix = 0
    if unsupported_profile[index:index + 3] == b"\x00\x00\x01":
        prefix = 3
    elif unsupported_profile[index:index + 4] == b"\x00\x00\x00\x01":
        prefix = 4
    if prefix:
        nal = index + prefix
        if unsupported_profile[nal] & 0x1f == 7 and nal + 3 < len(unsupported_profile):
            unsupported_profile[nal + 1] = 244
            unsupported_profile[nal + 3] = 255
            profile_mutated = True
            break
        index += prefix + 1
    else:
        index += 1
if not profile_mutated:
    raise SystemExit("could not locate AVC SPS for unsupported-profile vector")
write_records("unsupported-profile.records", [bytes(unsupported_profile)] + units[1:])
(target / "empty.records").write_bytes(b"")
(target / "truncated-header.records").write_bytes(b"\x00" * 8)
(target / "length-mismatch.records").write_bytes(record.pack(0, 0, 100) + b"x")

def read_records(path):
    result = []
    data = path.read_bytes()
    offset = 0
    while offset < len(data):
        if len(data) - offset < record.size:
            raise SystemExit("truncated generated HEVC record header")
        pts, flags, size = record.unpack_from(data, offset)
        offset += record.size
        if size > len(data) - offset:
            raise SystemExit("truncated generated HEVC record payload")
        result.append([pts, flags, data[offset:offset + size]])
        offset += size
    return result

def hevc_nal_units(data):
    starts = []
    index = 0
    while index + 5 < len(data):
        if data[index:index + 3] == b"\x00\x00\x01":
            starts.append((index, 3))
            index += 3
        elif data[index:index + 4] == b"\x00\x00\x00\x01":
            starts.append((index, 4))
            index += 4
        else:
            index += 1
    result = []
    for unit_index, (start, prefix) in enumerate(starts):
        end = starts[unit_index + 1][0] if unit_index + 1 < len(starts) else len(data)
        if start + prefix + 1 < end:
            nal_type = (data[start + prefix] >> 1) & 0x3f
            result.append((nal_type, data[start:end]))
    return result

hevc = read_records(hevc_records)
removed = set()
for value in hevc:
    units = hevc_nal_units(value[2])
    present = {nal_type for nal_type, _ in units}
    if present & {32, 33, 34}:
        value[2] = b"".join(
            payload for nal_type, payload in units if nal_type not in {32, 33, 34}
        )
        removed.update(present & {32, 33, 34})
        break
if removed != {32, 33, 34}:
    raise SystemExit(f"could not remove HEVC VPS/SPS/PPS; removed={sorted(removed)}")
with (target / "missing-hevc-config.records").open("wb") as output:
    for pts, flags, payload in hevc:
        output.write(record.pack(pts, flags, len(payload)))
        output.write(payload)
first_pts, first_flags, first_payload = hevc[0]
truncated = first_payload[:max(8, len(first_payload) // 4)]
with (target / "truncated-hevc.records").open("wb") as output:
    output.write(record.pack(first_pts, first_flags, len(truncated)))
    output.write(truncated)
PY_ERROR_VECTORS

expect_pipe_failure() {
    name="$1"
    input="$2"
    codec="${3:-avc}"
    width="${4:-1280}"
    height="${5:-720}"
    bitrate="${6:-4000000}"
    echo "STAGE: expecting isolated rejection for $name" | tee -a "$log"
    if timeout 30 dawnshell-codec pipe decode "$codec" "$width" "$height" \
        30 "$bitrate" \
        < "$input" > /dev/null 2>> "$log"; then
        echo "FAIL: malformed case unexpectedly succeeded: $name" | tee -a "$log" >&2
        exit 1
    fi
    sleep 0.2
    dawnshell-codec health --format json >> "$log"
}

dawnshell-codec health --format json > "$before"
echo "STAGE: protocol, state-machine, duplicate-EOS, and recovery errors" | tee -a "$log"
dawnshell-codec negative-test >> "$log" 2>&1
if [ "${DAWNSHELL_CODEC_TEST_IDLE_TIMEOUT:-1}" = 1 ]; then
    echo "STAGE: idle peer timeout and broker recovery" | tee -a "$log"
    timeout 45 dawnshell-codec idle-test 32000 >> "$log" 2>&1
fi
echo "STAGE: slow output consumer receives bounded backpressure" | tee -a "$log"
timeout 30 dawnshell-codec slow-output-test >> "$log" 2>&1
expect_pipe_failure empty-input "$temporary/empty.records"
expect_pipe_failure truncated-record-header "$temporary/truncated-header.records"
expect_pipe_failure payload-length-mismatch "$temporary/length-mismatch.records"
expect_pipe_failure missing-sps-pps "$temporary/missing-config.records"
expect_pipe_failure truncated-h264 "$temporary/truncated-bitstream.records"
expect_pipe_failure missing-vps-sps-pps "$temporary/missing-hevc-config.records" \
    hevc 1920 1080 8000000
expect_pipe_failure truncated-hevc "$temporary/truncated-hevc.records" \
    hevc 1920 1080 8000000

echo "STAGE: damaged packet may be rejected or concealably decoded" | tee -a "$log"
if timeout 30 dawnshell-codec pipe decode avc 1280 720 30 4000000 \
    < "$temporary/damaged.records" > /dev/null 2>> "$log"; then
    echo "PASS: vendor decoder recovered the damaged public vector" | tee -a "$log"
else
    echo "PASS: vendor decoder rejected the damaged public vector in-session" | tee -a "$log"
fi

echo "STAGE: unsupported AVC profile/level remains session-isolated" | tee -a "$log"
if timeout 30 dawnshell-codec pipe decode avc 1280 720 30 4000000 \
    < "$temporary/unsupported-profile.records" > /dev/null 2>> "$log"; then
    echo "PASS: vendor decoder conservatively accepted the mutated SPS" | tee -a "$log"
else
    echo "PASS: vendor decoder rejected the mutated SPS in-session" | tee -a "$log"
fi

echo "STAGE: parameter limit rejection" | tee -a "$log"
if dawnshell-codec probe decode avc 4096 4096 >> "$log" 2>&1; then
    echo "FAIL: oversized decoder parameters unexpectedly succeeded" | tee -a "$log" >&2
    exit 1
fi

echo "STAGE: abrupt decoder and Surface-transcoder peer cleanup" | tee -a "$log"
dawnshell-codec orphan-test decode >> "$log" 2>&1
dawnshell-codec orphan-test transcode >> "$log" 2>&1
sleep 2
dawnshell-codec health --format json > "$after"
"$adapter" validate-balanced-health "$before" "$after" 14 | tee -a "$log"

echo "DawnShell codec error isolation test passed"
echo "Evidence: $result_dir"
