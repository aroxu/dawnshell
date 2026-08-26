#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client="$repo_dir/app/src/main/cpp/dawnshell_codec_client.c"
worker="$repo_dir/app/src/main/cpp/dawnshell_codec_worker.c"
ndk_codec="$repo_dir/app/src/main/cpp/dawnshell_codec_ndk.c"
transport="$repo_dir/app/src/main/cpp/dawnshell_codec_transport.h"
namespace_launcher="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
runtime="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecService.java"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
ffmpeg_adapter="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-ffmpeg.py"
live_encode="$repo_dir/app/src/main/assets/bfu/dawnshell-live-encode.sh"
temporary_client=""
wrapper_dir=""
cleanup() {
    [[ -z "$temporary_client" ]] || rm -f -- "$temporary_client"
    [[ -z "$wrapper_dir" ]] || rm -rf -- "$wrapper_dir"
}
trap cleanup EXIT

for source in "$client" "$worker" "$ndk_codec" "$transport" \
        "$namespace_launcher" "$runtime" "$service" "$configurator" \
        "$ffmpeg_adapter"; do
    test -f "$source"
done

# The Debian data path is a one-client/one-worker inherited transport. It has
# no listener, pathname, peer authentication race, or descriptor transfer.
grep -Fq '#define DSCW_TRANSPORT_MAGIC 0x44534357u' "$transport"
grep -Fq '#define DSCW_MAX_PAYLOAD (8u * 1024u * 1024u)' "$transport"
grep -Fq '#define DSCW_WORKER_MEMFD 3' "$transport"
grep -Fq '#define DSCW_WORKER_REQUEST_EVENTFD 4' "$transport"
grep -Fq '#define DSCW_WORKER_RESPONSE_EVENTFD 5' "$transport"
grep -Fq 'DSCW_FLAG_WORKER_READY' "$transport"
grep -Fq 'eventfd(0, EFD_CLOEXEC)' "$client"
grep -Fq 'fork()' "$client"
grep -Fq 'execl(path, path, "--inherited-transport"' "$client"
grep -Fq 'prctl(PR_SET_PDEATHSIG, SIGTERM)' "$client" "$worker"
grep -Fq 'reap_worker_for(1000)' "$client"
grep -Fq 'kill(worker.child, SIGKILL)' "$client"
grep -Fq 'child_configure_android_linker()' "$client"
grep -Fq 'unsetenv(unsafe_variables[index])' "$client"
grep -Fq '/apex/com.android.i18n/lib64/libandroidicu.so' "$client"
grep -Fq '/apex/com.android.i18n/lib/libandroidicu.so' "$client"
grep -Fq 'setenv("LD_LIBRARY_PATH", icu_directory, 1)' "$client"
grep -Fq 'dscw_request_slot(worker.mapping)' "$client"
grep -Fq 'dscw_response_slot(worker.mapping)' "$client"
grep -Fq 'transport=inherited_memfd_eventfd' "$client"
grep -Fq 'public_listener\":false' "$worker"
grep -Fq 'descriptor_transfer\":false' "$worker"
grep -Fq 'AMediaCodec_createCodecByName' "$ndk_codec"
grep -Fq 'AMediaCodec_dequeueInputBuffer' "$ndk_codec"
grep -Fq 'AMediaCodec_dequeueOutputBuffer' "$ndk_codec"
grep -Fq 'AImageReader_new(' "$ndk_codec"
grep -Fq 'AMediaCodecStore_findNextEncoderForFormat' "$ndk_codec"
grep -Fq 'OMX.qcom.' "$ndk_codec"
grep -Fq 'c2.qti.' "$ndk_codec"

if grep -Eq 'AF_UNIX|SOCKET_NAME|SCM_RIGHTS|sendmsg\(|recvmsg\(' \
        "$client" "$worker" "$ndk_codec" "$transport"; then
    echo 'private NDK worker transport must not use Unix sockets or SCM_RIGHTS' >&2
    exit 1
fi
for removed in CodecSocket.java HardwareCodecBroker.java HardwareCodecProtocol.java; do
    test ! -e "$repo_dir/app/src/main/java/me/aroxu/dawnshell/$removed"
done
if grep -Fq 'ensureBrokerStarted' "$service"; then
    echo 'app-local codec service must not open a Debian broker' >&2
    exit 1
fi

# The bionic worker gets only immutable Android runtime trees in the private
# Debian mount namespace. No CE or app-private tree is exposed.
grep -Fq 'bind_android_runtime_tree(root, "/system", "system", true)' \
    "$namespace_launcher"
grep -Fq 'bind_android_runtime_tree(root, "/apex", "apex", true)' \
    "$namespace_launcher"
grep -Fq 'MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV' \
    "$namespace_launcher"
grep -Fq 'bind_android_runtime_tree /system system true' "$configurator"
grep -Fq 'bind_android_runtime_tree /apex apex true' "$configurator"
grep -Fq 'no app data or CE storage' "$configurator"
grep -Fq 'codecWorkerBinary = new File(bin, "dawnshell-codec-worker")' "$runtime"
grep -Fq 'dawnshell-codec-worker.new' "$configurator"
grep -Fq '/usr/local/libexec/dawnshell-codec-worker' "$configurator"

bash -n "$configurator" "$live_encode"
python3 - "$ffmpeg_adapter" <<'PYTHON_SYNTAX_CHECK'
import pathlib
import sys
compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")
PYTHON_SYNTAX_CHECK

# The parser remains host-testable without starting an Android worker.
vector="$repo_dir/app/src/main/assets/bfu/codec-test/avc-baseline-128x96-10fps.h264"
vector_720="$repo_dir/app/src/main/assets/bfu/codec-test/avc-baseline-1280x720-30fps-30f.h264"
vector_1080="$repo_dir/app/src/main/assets/bfu/codec-test/avc-high-1920x1080-30fps-60f.h264"
if [[ "$(uname -s)" == Linux* ]]; then
    temporary_client="$(mktemp)"
    gcc -std=c17 -O2 -Wall -Wextra -Werror "$client" -o "$temporary_client"
    "$temporary_client" inspect-vector "$vector" 10 \
        | grep -Fqx 'annex_b_bytes=11568 access_units=10'
    "$temporary_client" inspect-vector "$vector_720" 30 \
        | grep -Fqx 'annex_b_bytes=374216 access_units=30'
    "$temporary_client" inspect-vector "$vector_1080" 60 \
        | grep -Fqx 'annex_b_bytes=971544 access_units=60'
fi

for abi in armeabi-v7a arm64-v8a x86_64; do
    directory="$repo_dir/app/src/main/assets/bfu/bin/$abi"
    test -s "$directory/dawnshell-codec"
    test -s "$directory/dawnshell-codec-worker"
    grep -Fqx 'dawnshell_codec_protocol=1' "$directory/runtime.properties"
    grep -Fqx 'dawnshell_codec_transport=inherited_memfd_eventfd' \
        "$directory/runtime.properties"
    grep -Fqx 'dawnshell_codec_worker=ndk_mediacodec' \
        "$directory/runtime.properties"
done

# Generated FFmpeg wrappers must remain valid shell and keep the familiar
# ffmpeg syntax contract.
wrapper_dir="$(mktemp -d)"
python3 - "$configurator" "$wrapper_dir" <<'PYTHON_EXTRACT_WRAPPERS'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
target = pathlib.Path(sys.argv[2])
for name, marker in {
    "dawnshell-hwdecode": "EOF_CODEC_FFMPEG",
    "dawnshell-hwencode": "EOF_CODEC_FFMPEG_ENCODE",
    "dawnshell-hwtranscode": "EOF_CODEC_SURFACE_TRANSCODE",
}.items():
    opening = f"cat > /usr/local/bin/{name} <<'{marker}'\n"
    begin = source.index(opening) + len(opening)
    end = source.index(f"\n{marker}\n", begin)
    (target / name).write_text(source[begin:end] + "\n", encoding="utf-8")
PYTHON_EXTRACT_WRAPPERS
bash -n "$wrapper_dir/dawnshell-hwdecode"
bash -n "$wrapper_dir/dawnshell-hwencode"
bash -n "$wrapper_dir/dawnshell-hwtranscode"
grep -Fq 'cat > /usr/local/bin/dawnshell-ffmpeg' "$configurator"
# Literal generated-script fragments; expansion here would test the host shell.
# shellcheck disable=SC2016
grep -Fq 'pipe encode "$codec"' "$configurator"
# shellcheck disable=SC2016
grep -Fq 'pipe decode "$input_codec"' "$configurator"
# shellcheck disable=SC2016
grep -Fq 'dawnshell-codec transcode "$input_codec" avc' "$configurator"
grep -Fq 'dawnshell-codec pipe encode avc' "$live_encode"

echo 'Hardware codec NDK worker checks passed'
