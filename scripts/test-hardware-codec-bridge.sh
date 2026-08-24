#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
java_protocol="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecProtocol.java"
broker="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecBroker.java"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecService.java"
client="$repo_dir/app/src/main/cpp/dawnshell_codec_client.c"
runtime="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
ffmpeg_adapter="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-ffmpeg.py"

grep -Fq 'MAGIC = 0x44534342' "$java_protocol"
grep -Fq 'VERSION = 1' "$java_protocol"
grep -Fq 'MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024' "$java_protocol"
grep -Fq 'socket.getPeerCredentials()' "$broker"
grep -Fq 'credentials.getUid() != 0' "$broker"
grep -Fq 'MAX_SESSIONS_PER_PEER' "$broker"
grep -Fq 'payload length exceeds limit' "$broker"
grep -Fq 'HardwareCodecProtocol.INPUT' "$broker"
grep -Fq 'HardwareCodecProtocol.OUTPUT' "$broker"
grep -Fq 'HardwareCodecProtocol.FLUSH' "$broker"
grep -Fq 'HardwareCodecProtocol.EOS' "$broker"
grep -Fq 'HardwareCodecProtocol.CLOSE' "$broker"
grep -Fq 'HardwareCodecProtocol.INPUT_SHARED_MEMORY' "$broker"
grep -Fq 'HardwareCodecProtocol.OUTPUT_SHARED_MEMORY' "$broker"
grep -Fq 'HardwareCodecProtocol.CREATE_TRANSCODER' "$broker"
grep -Fq 'encoder.createInputSurface()' "$broker"
grep -Fq 'decoder.configure(decoderFormat, inputSurface' "$broker"
grep -Fq 'decoder.releaseOutputBuffer(index, info.size > 0)' "$broker"
grep -Fq 'encoder.signalEndOfInputStream()' "$broker"
grep -Fq 'peer.getAncillaryFileDescriptors()' "$broker"
grep -Fq 'Os.pread(descriptor' "$broker"
grep -Fq 'Os.pwrite(descriptor' "$broker"
grep -Fq 'ensureBrokerStarted()' "$service"

grep -Fq '#define DSCB_MAGIC 0x44534342u' "$client"
grep -Fq '#define DSCB_VERSION 1u' "$client"
grep -Fq '#define DSCB_SOCKET_NAME "dawnshell.codec.v1"' "$client"
grep -Fq 'address.sun_path[0]' "$client"
grep -Fq 'pipe stdin/stdout records are:' "$client"
grep -Fq 'run_decode_test' "$client"
grep -Fq 'run_encode_test' "$client"
grep -Fq 'inspect_vector' "$client"
grep -Fq '#define DSCB_INPUT_SHARED_MEMORY 9u' "$client"
grep -Fq '#define DSCB_OUTPUT_SHARED_MEMORY 10u' "$client"
grep -Fq '#define DSCB_CREATE_TRANSCODER 11u' "$client"
grep -Fq '__NR_memfd_create' "$client"
grep -Fq 'SCM_RIGHTS' "$client"
grep -Fq 'DAWNSHELL_CODEC_DISABLE_SHM' "$client"

grep -Fq 'codecClientBinary = new File(bin, "dawnshell-codec")' "$runtime"
grep -Fq 'codecFfmpegAdapterScript = new File(scripts' "$runtime"
grep -Fq 'hardware_codec_client=/usr/local/bin/dawnshell-codec' "$configurator"
grep -Fq 'hardware_codec_self_test=/usr/local/bin/dawnshell-codec-self-test' \
    "$configurator"
grep -Fq 'hardware_codec_decode=/usr/local/bin/dawnshell-hwdecode' "$configurator"
grep -Fq 'hardware_codec_encode=/usr/local/bin/dawnshell-hwencode' "$configurator"
grep -Fq 'hardware_codec_transcode=/usr/local/bin/dawnshell-hwtranscode' \
    "$configurator"
grep -Fq 'ffmpeg -hide_banner -loglevel error -f h264' "$configurator"
grep -Fq 'python3-minimal' "$configurator"
grep -Fq 'cat > /usr/local/bin/dawnshell-hwdecode' "$configurator"
grep -Fq 'cat > /usr/local/bin/dawnshell-hwencode' "$configurator"
grep -Fq 'cat > /usr/local/bin/dawnshell-hwtranscode' "$configurator"
grep -Fq 'hevc_mp4toannexb' "$configurator"
grep -Fq 'h264_mp4toannexb' "$configurator"
grep -Fq '/usr/local/libexec/dawnshell-codec-ffmpeg.py pack' "$configurator"
test -f "$ffmpeg_adapter"
python3 - "$ffmpeg_adapter" <<'PYTHON_SYNTAX_CHECK'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PYTHON_SYNTAX_CHECK
# shellcheck disable=SC2016 # Assert literal generated shell source.
grep -Fq 'encoded_frames="$(ffprobe' "$configurator"
vector="$repo_dir/app/src/main/assets/bfu/codec-test/avc-baseline-128x96-10fps.h264"
metadata="$repo_dir/app/src/main/assets/bfu/codec-test/avc-baseline-128x96-10fps.properties"
printf '%s  %s\n' \
    7a9ccdf88db5e89f404a7a15e98e4c57f11c396c880d00fe8ae8d5775f50588e \
    "$vector" | sha256sum -c -
grep -Fqx \
    'decoded_i420_sha256=777feb39bd92b899fc9cf7c184396e3ecec4fdbcd7a582fc560fc37011f18053' \
    "$metadata"
if [[ "$(uname -s)" == Linux* ]]; then
    temporary_client="$(mktemp)"
    trap 'rm -f -- "$temporary_client"' EXIT
    gcc -std=c17 -O2 -Wall -Wextra -Werror "$client" -o "$temporary_client"
    "$temporary_client" inspect-vector "$vector" 10 \
        | grep -Fqx 'annex_b_bytes=11568 access_units=10'
fi
for abi in armeabi-v7a arm64-v8a x86_64; do
    test -s "$repo_dir/app/src/main/assets/bfu/bin/$abi/dawnshell-codec"
    grep -Fqx 'dawnshell_codec_protocol=1' \
        "$repo_dir/app/src/main/assets/bfu/bin/$abi/runtime.properties"
done

adapter_test_dir="$(mktemp -d)"
cleanup_adapter_test() {
    rm -rf -- "$adapter_test_dir"
}
trap cleanup_adapter_test EXIT
printf '\000\000\000\001abc\000\000\001defg' > "$adapter_test_dir/input.h264"
printf '%s\n' \
    '{"packets":[{"pts_time":"1.000000"},{"pts_time":"1.040000"}]}' \
    > "$adapter_test_dir/input.json"
printf '%s\n' \
    '{"packets":[{"pos":"0","size":"7"},{"pos":"7","size":"7"}]}' \
    > "$adapter_test_dir/raw.json"
python3 "$ffmpeg_adapter" pack "$adapter_test_dir/input.json" \
    "$adapter_test_dir/raw.json" "$adapter_test_dir/input.h264" 25/1 \
    "$adapter_test_dir/framed.bin" | grep -Fqx 'packed_packets=2 pts_shift_us=1000000'
python3 - "$adapter_test_dir/decoded.bin" <<'PYTHON_DECODE_RECORD'
import pathlib
import struct
import sys

frame = bytes(range(24))
pathlib.Path(sys.argv[1]).write_bytes(
    struct.pack(">QII", 0, 0, len(frame)) + frame
    + struct.pack(">QII", 40_000, 4, len(frame)) + frame
)
PYTHON_DECODE_RECORD
python3 "$ffmpeg_adapter" unpack "$adapter_test_dir/decoded.bin" \
    "$adapter_test_dir/decoded.i420" 4 4 | grep -Fqx 2
test "$(wc -c < "$adapter_test_dir/decoded.i420")" -eq 48
python3 "$ffmpeg_adapter" pack-i420 "$adapter_test_dir/decoded.i420" \
    4 4 25/1 "$adapter_test_dir/framed-i420.bin" | grep -Fqx 2
python3 - "$adapter_test_dir/encoded.bin" <<'PYTHON_ENCODE_RECORD'
import pathlib
import struct
import sys

pathlib.Path(sys.argv[1]).write_bytes(
    struct.pack(">QII", 0, 2, 4) + b"csd0"
    + struct.pack(">QII", 0, 0, 3) + b"one"
    + struct.pack(">QII", 40_000, 4, 3) + b"two"
)
PYTHON_ENCODE_RECORD
python3 "$ffmpeg_adapter" unpack-annexb "$adapter_test_dir/encoded.bin" \
    "$adapter_test_dir/output.h264" | grep -Fqx 2
test "$(wc -c < "$adapter_test_dir/output.h264")" -eq 10

echo "Hardware codec broker protocol, client, and three-ABI assets are pinned"
