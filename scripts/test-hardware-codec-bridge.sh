#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
java_protocol="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecProtocol.java"
broker="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecBroker.java"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecService.java"
activity="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootActivity.java"
file_self_test="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecFileSelfTest.java"
long_run_control="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecLongRun.java"
recovery_test="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecRecoveryTest.java"
su_runner="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuSu.java"
client="$repo_dir/app/src/main/cpp/dawnshell_codec_client.c"
namespace_launcher="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
runtime="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
ffmpeg_adapter="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-ffmpeg.py"
long_run="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-long-run.sh"
concurrency_test="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-concurrency-test.sh"
error_test="$repo_dir/app/src/main/assets/bfu/dawnshell-codec-error-test.sh"
live_encode="$repo_dir/app/src/main/assets/bfu/dawnshell-live-encode.sh"
boot_layout="$repo_dir/app/src/main/res/layout/activity_boot.xml"
english_strings="$repo_dir/app/src/main/res/values/strings.xml"
korean_strings="$repo_dir/app/src/main/res/values-ko/strings.xml"
ffmpeg_guide="$repo_dir/docs/ffmpeg-hardware-codec.md"
ffmpeg_guide_ko="$repo_dir/docs/ffmpeg-hardware-codec.ko.md"
mediacodec_guide="$repo_dir/docs/ffmpeg-mediacodec-compatibility.md"
mediacodec_guide_ko="$repo_dir/docs/ffmpeg-mediacodec-compatibility.ko.md"

grep -Fq 'MAGIC = 0x44534342' "$java_protocol"
grep -Fq 'VERSION = 1' "$java_protocol"
grep -Fq 'MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024' "$java_protocol"
# Android's LocalSocket stream API fails with EMSGSIZE when a message carries
# an SCM_RIGHTS descriptor, so the broker must own a plain AF_UNIX socket and
# call recvmsg itself.
codec_socket="$repo_dir/app/src/main/java/me/aroxu/dawnshell/CodecSocket.java"
codec_socket_jni="$repo_dir/app/src/main/cpp/codec_socket_jni.c"
test -f "$codec_socket"
test -f "$codec_socket_jni"
grep -Fq 'CodecSocket.listen(' "$broker"
grep -Fq 'peer.receiveFully(' "$broker"
grep -Fq 'peer.sendFully(' "$broker"
grep -Fq 'recvmsg(descriptor, &message, 0)' "$codec_socket_jni"
grep -Fq 'SCM_RIGHTS' "$codec_socket_jni"
grep -Fq 'SO_PEERCRED' "$codec_socket_jni"
if grep -Fq 'android.net.LocalSocket' "$broker"; then
    echo "the broker must not use LocalSocket for descriptor passing" >&2
    exit 1
fi
grep -Fq 'peerUid != 0' "$broker"
if grep -Fq 'peerUid != Process.myUid()' "$broker"; then
    echo "Hardware codec broker must not authenticate app-UID socket peers" >&2
    exit 1
fi
grep -Fq 'ConcurrentHashMap.newKeySet()' "$broker"
grep -Fq 'peerSockets.add(socket)' "$broker"
grep -Fq 'peerSockets.remove(socket)' "$broker"
grep -Fq 'peer.close()' "$broker"
grep -Fq 'awaitExecutor(acceptExecutor, "accept loop")' "$broker"
grep -Fq 'awaitExecutor(peerExecutor, "peer cleanup")' "$broker"
grep -Fq 'MAX_SESSIONS_PER_PEER' "$broker"
grep -Fq 'MAX_PEERS = 4' "$java_protocol"
grep -Fq 'if (!reservePeer())' "$broker"
grep -Fq 'reason=peer_limit' "$broker"
grep -Fq 'root.put("max_peers", HardwareCodecProtocol.MAX_PEERS)' "$broker"
grep -Fq 'payload length exceeds limit' "$broker"
grep -Fq 'HardwareCodecProtocol.INPUT' "$broker"
grep -Fq 'HardwareCodecProtocol.OUTPUT' "$broker"
grep -Fq 'HardwareCodecProtocol.FLUSH' "$broker"
grep -Fq 'HardwareCodecProtocol.EOS' "$broker"
grep -Fq 'HardwareCodecProtocol.CLOSE' "$broker"
grep -Fq 'HardwareCodecProtocol.INPUT_SHARED_MEMORY' "$broker"
grep -Fq 'HardwareCodecProtocol.OUTPUT_SHARED_MEMORY' "$broker"
grep -Fq 'HardwareCodecProtocol.CREATE_TRANSCODER' "$broker"
grep -Fq 'HardwareCodecProtocol.REQUEST_KEYFRAME' "$broker"
grep -Fq 'HardwareCodecProtocol.HEALTH' "$broker"
grep -Fq 'HardwareCodecProtocol.SESSION_STATS' "$broker"
grep -Fq 'MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME' "$broker"
grep -Fq 'surface_zero_copy' "$broker"
grep -Fq 'software_fallback' "$broker"
grep -Fq 'encoder.createInputSurface()' "$broker"
grep -Fq 'decoder.configure(decoderFormat, inputSurface' "$broker"
grep -Fq 'decoder.releaseOutputBuffer(index, info.size > 0)' "$broker"
grep -Fq 'encoder.signalEndOfInputStream()' "$broker"
grep -Fq 'wrapDescriptor(' "$broker"
grep -Fq 'Os.pread(descriptor' "$broker"
grep -Fq 'Os.pwrite(descriptor' "$broker"
grep -Fq 'ensureBrokerStarted()' "$service"

# The bridge must come up on its own after a reboot in both AFU and BFU. It
# once required opening the app by hand, which silently broke every Debian
# codec command after a restart.
boot_receiver="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootReceiver.java"
grep -Fq 'startHardwareCodecBridge(context' "$boot_receiver"
grep -Fq 'HardwareCodecService.ensureStarted(context, bootRetry)' "$boot_receiver"
grep -Fq 'HardwareCodecService.ensureStarted(this, !userUnlocked)' \
    "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuBootService.java"
python3 - "$boot_receiver" <<'PYTHON_VERIFY_BOOT_PATHS'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("public void onReceive(")
end = source.index("\n    private static void startHardwareCodecBridge", start)
body = source[start:end]
locked = body.index("ACTION_LOCKED_BOOT_COMPLETED")
completed = body.index("ACTION_BOOT_COMPLETED")
if "startHardwareCodecBridge" not in body[locked:completed]:
    raise SystemExit("locked boot never starts the codec bridge")
if "startHardwareCodecBridge" not in body[completed:]:
    raise SystemExit("boot completed never starts the codec bridge")
print("codec bridge starts from both locked boot and boot completed")
PYTHON_VERIFY_BOOT_PATHS
grep -Fq 'ACTION_FILE_SELF_TEST' "$service"
grep -Fq 'HardwareCodecFileSelfTest.run(this, token)' "$service"
grep -Fq 'Big_Buck_Bunny_1080_10s_5MB.mp4' "$file_self_test"
grep -Fq 'MediaExtractor' "$file_self_test"
grep -Fq 'transport=device_protected_file socket_media_bytes=0' "$file_self_test"
grep -Fq 'downloaded_by", "debian_wget"' "$file_self_test"
if grep -Eq 'HttpURLConnection|openConnection\(' "$file_self_test"; then
    echo "The file self-test must download through Debian wget, not Android" >&2
    exit 1
fi
grep -Fq 'apt-get install -y wget ca-certificates' "$activity"
grep -Fq 'wget --timeout=30 --tries=3' "$activity"
grep -Fq 'HardwareCodecService.requestFileSelfTest(this)' "$activity"
grep -Fq 'showFfmpegCodecGuide()' "$activity"
grep -Fq 'showLiveCodecGuide()' "$activity"
grep -Fq 'copyFfmpegCodecGuide(guide)' "$activity"
grep -Fq 'dawnshell-live-encode.sh' "$runtime"
grep -Fq 'open_ffmpeg_codec_guide_button' "$boot_layout"
grep -Fq 'open_live_codec_guide_button' "$boot_layout"
grep -Fq 'dawnshell_codec_ffmpeg_guide_body' "$english_strings"
grep -Fq 'dawnshell_codec_ffmpeg_guide_body' "$korean_strings"
grep -Fq 'sudo env DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg' "$english_strings"
grep -Fq 'sudo env DAWNSHELL_FFMPEG_BRIDGE=require dawnshell-ffmpeg' "$korean_strings"
grep -Fq 'sudo bash -x /usr/local/bin/dawnshell-hwtranscode' "$english_strings"
grep -Fq 'sudo bash -x /usr/local/bin/dawnshell-hwtranscode' "$korean_strings"
grep -Fq 'dawnshell_codec_live_guide_body' "$english_strings"
grep -Fq 'dawnshell_codec_live_guide_body' "$korean_strings"
grep -Fq 'dawnshell-live-encode --input /dev/video0' \
    "$english_strings" "$korean_strings"
grep -Fq 'socket/shared-memory streaming' "$ffmpeg_guide"
grep -Fq 'socket/공유' "$ffmpeg_guide_ko"
grep -Fq 'sudo dawnshell-ffmpeg-integration enable' \
    "$ffmpeg_guide" "$ffmpeg_guide_ko"
grep -Fq 'sudo dawnshell-ffmpeg-integration disable' \
    "$ffmpeg_guide" "$ffmpeg_guide_ko" "$mediacodec_guide" "$mediacodec_guide_ko"
grep -Fq 'plan-ffmpeg' "$ffmpeg_guide" "$ffmpeg_guide_ko"
grep -Fq 'sudo bash -x /usr/local/bin/dawnshell-hwtranscode' \
    "$ffmpeg_guide" "$ffmpeg_guide_ko"
grep -Fq '/usr/local/bin/dawnshell-codec transcode' \
    "$ffmpeg_guide" "$ffmpeg_guide_ko"
grep -Fq 'sudo env DAWNSHELL_FFMPEG_BRIDGE=require' \
    "$ffmpeg_guide" "$ffmpeg_guide_ko"
grep -Fq 'dawnshell-live-encode' "$ffmpeg_guide" "$ffmpeg_guide_ko"
grep -Fq -- '--hls-delete-segments' "$ffmpeg_guide" "$ffmpeg_guide_ko"

# The upstream-syntax contract must stay documented in both languages, since a
# silent software fallback behind an explicit -c:v h264_mediacodec would
# invalidate any performance or battery measurement.
test -f "$mediacodec_guide"
test -f "$mediacodec_guide_ko"
for mediacodec_doc in "$mediacodec_guide" "$mediacodec_guide_ko"; do
    grep -Fq -- '-hwaccel mediacodec' "$mediacodec_doc"
    grep -Fq 'h264_mediacodec' "$mediacodec_doc"
    grep -Fq 'hevc_mediacodec' "$mediacodec_doc"
    grep -Fq 'libmediandk' "$mediacodec_doc"
    grep -Fq 'DAWNSHELL_FFMPEG_BRIDGE=off' "$mediacodec_doc"
    grep -Fq 'explicit=mediacodec' "$mediacodec_doc"
    grep -Fq 'plan-ffmpeg' "$mediacodec_doc"
done
grep -Fq 'ffmpeg-mediacodec-compatibility.md' "$repo_dir/README.md" \
    "$ffmpeg_guide" "$repo_dir/docs/user-guide.md"
grep -Fq 'ffmpeg-mediacodec-compatibility.ko.md' "$repo_dir/README.ko.md" \
    "$ffmpeg_guide_ko" "$repo_dir/docs/user-guide.ko.md"
grep -Fq 'dawnshell_codec_mediacodec_syntax_body' "$english_strings" \
    "$korean_strings" "$activity"
grep -Fq 'h264_mediacodec' "$english_strings" "$korean_strings"

# Every relative Markdown link in the new documents must resolve on disk.
python3 - "$mediacodec_guide" "$mediacodec_guide_ko" <<'PYTHON_VERIFY_LINKS'
import pathlib
import re
import sys

for argument in sys.argv[1:]:
    document = pathlib.Path(argument)
    text = document.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)]+)\)", text):
        if target.startswith(("http://", "https://", "#")):
            continue
        resolved = (document.parent / target.split("#", 1)[0]).resolve()
        if not resolved.exists():
            raise SystemExit(f"{document.name}: broken link {target}")
print("MediaCodec compatibility documents have no broken links")
PYTHON_VERIFY_LINKS

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
grep -Fq '#define DSCB_REQUEST_KEYFRAME 12u' "$client"
grep -Fq '#define DSCB_HEALTH 13u' "$client"
grep -Fq '#define DSCB_SESSION_STATS 14u' "$client"
grep -Fq 'first-frame=key' "$client"
grep -Fq 'session-stats=' "$client"
grep -Fq 'negative-test passed rejected=16' "$client"
grep -Fq 'nonmonotonic-encoder-pts' "$client"
grep -Fq 'unknown-message-type' "$client"
grep -Fq 'invalid-magic' "$client"
grep -Fq 'invalid-version' "$client"
grep -Fq 'invalid-header-flags' "$client"
grep -Fq 'zero-request-id' "$client"
grep -Fq 'oversized-payload' "$client"
grep -Fq 'truncated-protocol-payload' "$client"
grep -Fq 'peer-limit-test passed max_peers=4 overflow=rejected' "$client"
grep -Fq 'signal(SIGPIPE, SIG_IGN)' "$client"
grep -Fq 'encoder frame PTS must increase monotonically' "$broker"
grep -Fq 'encoder EOS PTS precedes the last frame' "$broker"
grep -Fq 'zero-width-create' "$client"
grep -Fq 'oversized-frame-create' "$client"
grep -Fq 'session=responsive broker=responsive' "$client"
grep -Fq 'input-after-eos' "$client"
grep -Fq 'duplicate-eos' "$client"
grep -Fq 'hold-test decode|encode|transcode DURATION_MS' "$client"
grep -Fq 'idle-test DURATION_MS' "$client"
grep -Fq 'idle-test passed broker closed idle peer' "$client"
grep -Fq 'slow-output-test' "$client"
grep -Fq 'slow-output-test passed' "$client"
grep -Fq 'slow output consumer receives bounded backpressure' "$error_test"
# shellcheck disable=SC2016 # Assert literal runtime shell source.
grep -Fq 'validate-balanced-health "$before" "$after" 14' "$error_test"
grep -Fq 'pipe frame count mismatch' "$client"
grep -Fq 'input contains unsupported buffer flags' "$broker"
grep -Fq 'Process.getElapsedCpuTime()' "$broker"
grep -Fq 'Debug.getPss()' "$broker"
grep -Fq 'open_fd_count' "$broker"
grep -Fq 'thermal_status' "$broker"
grep -Fq 'peak_active_sessions' "$broker"
grep -Fq 'input_dequeue_timeouts' "$broker"
grep -Fq 'output_dequeue_timeouts' "$broker"
grep -Fq 'queue_depth_high_water' "$broker"
grep -Fq 'input_call_latency_avg_us' "$broker"
grep -Fq 'input_call_latency_max_us' "$broker"
grep -Fq 'output_call_latency_avg_us' "$broker"
grep -Fq 'output_call_latency_max_us' "$broker"
grep -Fq 'peak_input_payload_bytes' "$broker"
grep -Fq 'peak_output_payload_bytes' "$broker"
grep -Fq 'codec input is closed after EOS' "$broker"
grep -Fq 'codec EOS was already queued' "$broker"
grep -Fq '\"media_transport\"' "$broker"
grep -Fq 'transcode-test passed size=' "$client"
grep -Fq 'orphan-test abandoning' "$client"
grep -Fq '__NR_memfd_create' "$client"
grep -Fq 'SCM_RIGHTS' "$client"
grep -Fq 'DAWNSHELL_CODEC_DISABLE_SHM' "$client"

grep -Fq 'codecClientBinary = new File(bin, "dawnshell-codec")' "$runtime"
grep -Fq 'codecFfmpegAdapterScript = new File(scripts' "$runtime"
grep -Fq 'codec720pTestVector = new File(downloads' "$runtime"
grep -Fq 'codec1080pTestVector = new File(downloads' "$runtime"
grep -Fq 'codecBFrameContainerVector = new File(downloads' "$runtime"
grep -Fq 'codecHevcContainerVector = new File(downloads' "$runtime"
grep -Fq 'codecLongRunScript = new File(scripts' "$runtime"
grep -Fq 'codecConcurrencyTestScript = new File(scripts' "$runtime"
grep -Fq 'codecErrorTestScript = new File(scripts' "$runtime"
grep -Fq 'hardware_codec_client=/usr/local/bin/dawnshell-codec' "$configurator"
grep -Fq 'hardware_codec_self_test=/usr/local/bin/dawnshell-codec-self-test' \
    "$configurator"
grep -Fq 'hardware_codec_decode=/usr/local/bin/dawnshell-hwdecode' "$configurator"
grep -Fq 'hardware_codec_encode=/usr/local/bin/dawnshell-hwencode' "$configurator"
grep -Fq 'hardware_codec_transcode=/usr/local/bin/dawnshell-hwtranscode' \
    "$configurator"
grep -Fq 'input codec must be H.264 or HEVC' "$configurator"
grep -Fq 'bitstream_filter=hevc_mp4toannexb' "$configurator"
# shellcheck disable=SC2016 # Assert literal generated runtime shell source.
grep -Fq 'pipe decode "$input_codec"' "$configurator"
grep -Fq 'usage: dawnshell-hwencode INPUT OUTPUT [BITRATE] [avc|hevc]' \
    "$configurator"
# shellcheck disable=SC2016 # Assert literal generated runtime shell source.
grep -Fq 'pipe encode "$codec"' "$configurator"
grep -Fq 'elementary_format=hevc' "$configurator"
grep -Fq 'raw output suffix conflicts with codec' "$configurator"
grep -Fq 'validate-encoder-stats' "$configurator"
grep -Fq 'def validate_encoder_stats(arguments):' "$ffmpeg_adapter"
grep -Fq 'actual_bitrate_bps' "$ffmpeg_adapter"
grep -Fq 'hardware_codec_performance_test=/usr/local/bin/dawnshell-codec-performance-test' \
    "$configurator"
grep -Fq 'hardware_codec_long_run_test=/usr/local/bin/dawnshell-codec-long-run' \
    "$configurator"
grep -Fq 'hardware_codec_concurrency_test=/usr/local/bin/dawnshell-codec-concurrency-test' \
    "$configurator"
grep -Fq 'hardware_codec_error_test=/usr/local/bin/dawnshell-codec-error-test' \
    "$configurator"
grep -Fq 'ffmpeg -hide_banner -loglevel error -f h264' "$configurator"
# The minimal Python package omits decimal, which the codec adapter imports.
# Installing it once made every bridge command fail as a plain FFmpeg
# "Unknown encoder". Check the apt-get line, not prose in comments.
if grep -E '^ +bash passwd .*python3-minimal' "$configurator"; then
    echo 'FAIL: the minimal Python package lacks the decimal module' >&2
    exit 1
fi
grep -Fq 'ffmpeg python3' "$configurator"
grep -Fq 'for module in decimal json struct pathlib argparse' "$configurator"
# A dead planner must not silently degrade into a software encode.
grep -Fq 'the codec planner produced no plan' "$configurator"
grep -Fq 'refusing to fall back silently' "$configurator"
# A pipeline hides upstream failures behind its last command's status, which
# once surfaced a real encoder rejection as an unexplained broken pipe.
# shellcheck disable=SC2016 # Assert literal generated shell source.
grep -Fq 'stage_status="${PIPESTATUS[*]}"' "$configurator"
grep -Fq 'hardware-encoder' "$configurator"
# The response header travels as its own send so a large payload cannot be
# merged into one oversized write, which previously failed as "Message too
# long" for full-resolution frames.
python3 - "$broker" <<'PYTHON_VERIFY_RESPONSE_WRITE'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("private static void writeResponse(")
end = source.index("\n    }\n", start)
body = source[start:end]
header_send = body.index("peer.sendFully(header, 0, header.length)")
payload_send = body.index("peer.sendFully(payload, 0, payload.length)")
if header_send > payload_send:
    raise SystemExit("the response header must be sent before the payload")
print("broker sends the response header separately from the payload")
PYTHON_VERIFY_RESPONSE_WRITE
# An encoder consumes one raw frame, not the whole protocol payload.
grep -Fq 'width * height * 3 / 2);' "$broker"
grep -Fq 'cat > /usr/local/bin/dawnshell-hwdecode' "$configurator"
grep -Fq 'cat > /usr/local/bin/dawnshell-hwencode' "$configurator"
grep -Fq 'cat > /usr/local/bin/dawnshell-hwtranscode' "$configurator"
grep -Fq 'dawnshell-live-encode.new' "$configurator"
grep -Fq 'hardware_codec_live_encode=/usr/local/bin/dawnshell-live-encode' \
    "$configurator"
grep -Fq 'usbutils v4l-utils ffmpeg' "$configurator"
grep -Fq 'dawnshell-codec pipe encode avc' "$live_encode"
grep -Fq 'pack-i420 -' "$live_encode"
grep -Fq 'unpack-annexb - - --require-keyframe' "$live_encode"
grep -Fq 'hls_flags=independent_segments' "$live_encode"
grep -Fq 'hevc_mp4toannexb' "$configurator"
grep -Fq 'h264_mp4toannexb' "$configurator"
grep -Fq '/usr/local/libexec/dawnshell-codec-ffmpeg.py pack' "$configurator"
grep -Fq '/usr/local/libexec/dawnshell-codec-ffmpeg.py validate-stats' "$configurator"
grep -Fq 'dawnshell-codec health --format json' "$configurator"
grep -Fq 'cat > /usr/local/bin/dawnshell-codec-performance-test' "$configurator"
grep -Fq 'compare-decode-transports' "$configurator"
grep -Fq 'validate-cleanup' "$configurator"
grep -Fq 'compare-cpu-baseline' "$configurator"
grep -Fq 'validate-quality' "$configurator"
# shellcheck disable=SC2016 # Assert literal generated shell source.
grep -Fq 'validate-cleanup "$before_health" "$after_health" 14' "$configurator"
grep -Fq 'pipe:0' "$configurator"
grep -Fq 'pack-i420' "$configurator"
grep -Fq 'MP4 B-frame demux, timestamp reorder, and hardware decode' "$configurator"
grep -Fq 'HEVC MP4 to AVC Surface zero-copy pipeline' "$configurator"
grep -Fq '/usr/local/bin/dawnshell-codec-error-test' "$configurator"
grep -Fq '/usr/local/bin/dawnshell-codec-concurrency-test' "$configurator"
grep -Fq 'dawnshell-codec-long-run.service' "$configurator"
grep -Fq 'TimeoutStartSec=90min' "$configurator"
grep -Fq '/usr/bin/flock' "$configurator"
for script in "$long_run" "$concurrency_test" "$error_test"; do
    test -f "$script"
    grep -Fq 'DAWNSHELL_CODEC_TEST_LOCK_HELD' "$script"
done
grep -Fq 'summarize-health' "$long_run"
grep -Fq 'summarize-time-series' "$long_run"
grep -Fq 'load_average_start=' "$long_run"
grep -Fq 'validate-concurrency-health' "$concurrency_test"
grep -Fq 'validate-balanced-health' "$error_test"
grep -Fq 'missing-hevc-config.records' "$error_test"
grep -Fq 'DAWNSHELL_CODEC_TEST_IDLE_TIMEOUT' "$error_test"
grep -Fq 'codec-long-run /data/local/debian CONTROL_DIR' "$namespace_launcher"
grep -Fq 'dawnshell-codec-long-run.service' "$namespace_launcher"
grep -Fq 'start|stop|status|report' "$namespace_launcher"
grep -Fq "trap 'terminate 143' TERM" "$long_run"
grep -Fq 'static Result runRaw' "$su_runner"
grep -Fq 'DawnShell-su-output' "$su_runner"
grep -Fq 'enum Operation { START, STOP, STATUS }' "$long_run_control"
grep -Fq 'codec-long-run' "$long_run_control"
grep -Fq 'kill -9 ' "$recovery_test"
grep -Fq 'codec_broker_recovery=verified' "$recovery_test"
grep -Fq 'HardwareCodecService.ensureStarted(context, false)' "$recovery_test"
grep -Fq 'context.getPackageName() + ":codec"' "$recovery_test"
# shellcheck disable=SC2016 # Assert literal generated root-shell source.
grep -Fq '/proc/$pid/cmdline' "$recovery_test"
# shellcheck disable=SC2016 # Assert literal generated root-shell source.
grep -Fq '/proc/$pid/status' "$recovery_test"
grep -Fq 'HardwareCodecRecoveryTest.run(this, codecLayout)' \
    "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootActivity.java"
grep -Fq 'dawnshell-codec-unlock-hold.service' \
    "$repo_dir/scripts/test-systemd-ssh-bfu.sh"
grep -Fq '"user_unlocked":false' "$repo_dir/scripts/test-systemd-ssh-bfu.sh"
grep -Fq '"user_unlocked":true' "$repo_dir/scripts/test-systemd-ssh-bfu.sh"
grep -Fq 'embedded_codec_hash=' "$repo_dir/scripts/test-final-bfu.sh"
grep -Fq 'provisioned codec client does not match' \
    "$repo_dir/scripts/test-final-bfu.sh"
grep -Fq 'codec_bfu_pid' "$repo_dir/scripts/test-final-bfu.sh"
grep -Fq 'one continuous BFU-to-AFU codec PID' \
    "$repo_dir/scripts/test-final-bfu.sh"
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
vector_720="$repo_dir/app/src/main/assets/bfu/codec-test/avc-baseline-1280x720-30fps-30f.h264"
metadata_720="$repo_dir/app/src/main/assets/bfu/codec-test/avc-baseline-1280x720-30fps-30f.properties"
vector_1080="$repo_dir/app/src/main/assets/bfu/codec-test/avc-high-1920x1080-30fps-60f.h264"
metadata_1080="$repo_dir/app/src/main/assets/bfu/codec-test/avc-high-1920x1080-30fps-60f.properties"
vector_bframes="$repo_dir/app/src/main/assets/bfu/codec-test/avc-high-1280x720-30fps-30f-b2.mp4"
metadata_bframes="$repo_dir/app/src/main/assets/bfu/codec-test/avc-high-1280x720-30fps-30f-b2.properties"
vector_hevc="$repo_dir/app/src/main/assets/bfu/codec-test/hevc-main-1920x1080-30fps-60f.mp4"
metadata_hevc="$repo_dir/app/src/main/assets/bfu/codec-test/hevc-main-1920x1080-30fps-60f.properties"
printf '%s  %s\n' \
    7a9ccdf88db5e89f404a7a15e98e4c57f11c396c880d00fe8ae8d5775f50588e \
    "$vector" | sha256sum -c -
printf '%s  %s\n' \
    aa8cb11ff650c98d45b6975947024446e923cf055f3921189571bb8141d9c2a5 \
    "$vector_720" | sha256sum -c -
printf '%s  %s\n' \
    67ee26637911bb0ffc7b84749810b14cc7b3e35677f138be2c43448e33e1421b \
    "$vector_1080" | sha256sum -c -
printf '%s  %s\n' \
    1c88cf9b08d0527d83768171389d5bcc2a43075ace06b183fdfdcef3a633e57a \
    "$vector_bframes" | sha256sum -c -
printf '%s  %s\n' \
    2c6dae5d20ad02ddf08485440c888c361f4080df535c1803e3c74fd51259c8b2 \
    "$vector_hevc" | sha256sum -c -
grep -Fqx \
    'decoded_i420_sha256=777feb39bd92b899fc9cf7c184396e3ecec4fdbcd7a582fc560fc37011f18053' \
    "$metadata"
grep -Fqx \
    'decoded_i420_sha256=7ff494db80cf8a311468f9638384d3d7a7bd320b5b831110076b7c80979af26f' \
    "$metadata_720"
grep -Fqx 'frames=60' "$metadata_1080"
grep -Fqx \
    'decoded_i420_sha256=48630f45fa17f58a0435ff0cdb18e42ae466a449cd5d7f7ba966f277b2c8082e' \
    "$metadata_1080"
grep -Fqx 'has_b_frames=2' "$metadata_bframes"
grep -Fqx \
    'decoded_i420_sha256=484b59dce2d3a1ce58d0712583309f0a1ad8b0e0506ab226fb95191ef67cf437' \
    "$metadata_bframes"
grep -Fqx 'codec=HEVC/H.265' "$metadata_hevc"
grep -Fqx \
    'decoded_i420_sha256=a452cd360b635349b47f5c918364cef7e601735dbddbd94d50c435da74bf01d0' \
    "$metadata_hevc"
if [[ "$(uname -s)" == Linux* ]]; then
    temporary_client="$(mktemp)"
    trap 'rm -f -- "$temporary_client"' EXIT
    gcc -std=c17 -O2 -Wall -Wextra -Werror "$client" -o "$temporary_client"
    "$temporary_client" inspect-vector "$vector" 10 \
        | grep -Fqx 'annex_b_bytes=11568 access_units=10'
    "$temporary_client" inspect-vector "$vector_720" 30 \
        | grep -Fqx 'annex_b_bytes=374216 access_units=30'
    "$temporary_client" inspect-vector "$vector_1080" 60 \
        | grep -Fqx 'annex_b_bytes=971544 access_units=60'
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
python3 - "$configurator" "$adapter_test_dir" <<'PYTHON_EXTRACT_WRAPPERS'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
target = pathlib.Path(sys.argv[2])
wrappers = {
    "dawnshell-hwdecode": "EOF_CODEC_FFMPEG",
    "dawnshell-hwencode": "EOF_CODEC_FFMPEG_ENCODE",
    "dawnshell-hwtranscode": "EOF_CODEC_SURFACE_TRANSCODE",
}
for name, marker in wrappers.items():
    opening = f"cat > /usr/local/bin/{name} <<'{marker}'\n"
    try:
        begin = source.index(opening) + len(opening)
        end = source.index(f"\n{marker}\n", begin)
    except ValueError as error:
        raise SystemExit(f"could not extract generated {name}: {error}")
    (target / name).write_text(source[begin:end] + "\n", encoding="utf-8")
PYTHON_EXTRACT_WRAPPERS
bash -n "$adapter_test_dir/dawnshell-hwdecode"
bash -n "$adapter_test_dir/dawnshell-hwencode"
bash -n "$adapter_test_dir/dawnshell-hwtranscode"
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
python3 "$ffmpeg_adapter" unpack - - 4 4 \
    < "$adapter_test_dir/decoded.bin" \
    > "$adapter_test_dir/streamed.i420" \
    2> "$adapter_test_dir/unpack-stream.log"
cmp "$adapter_test_dir/decoded.i420" "$adapter_test_dir/streamed.i420"
grep -Fqx 'unpacked_i420_frames=2' "$adapter_test_dir/unpack-stream.log"
python3 "$ffmpeg_adapter" pack-i420 "$adapter_test_dir/decoded.i420" \
    4 4 25/1 "$adapter_test_dir/framed-i420.bin" | grep -Fqx 2
python3 "$ffmpeg_adapter" pack-i420 - 4 4 25/1 - \
    < "$adapter_test_dir/decoded.i420" \
    > "$adapter_test_dir/streamed-framed-i420.bin" \
    2> "$adapter_test_dir/pack-stream.log"
cmp "$adapter_test_dir/framed-i420.bin" \
    "$adapter_test_dir/streamed-framed-i420.bin"
grep -Fqx 'packed_i420_frames=2' "$adapter_test_dir/pack-stream.log"
python3 - "$adapter_test_dir/encoded.bin" <<'PYTHON_ENCODE_RECORD'
import pathlib
import struct
import sys

pathlib.Path(sys.argv[1]).write_bytes(
    struct.pack(">QII", 0, 2, 4) + b"csd0"
    + struct.pack(">QII", 0, 1, 3) + b"one"
    + struct.pack(">QII", 40_000, 4, 3) + b"two"
)
PYTHON_ENCODE_RECORD
python3 "$ffmpeg_adapter" unpack-annexb "$adapter_test_dir/encoded.bin" \
    "$adapter_test_dir/output.h264" --require-keyframe | grep -Fqx 2
test "$(wc -c < "$adapter_test_dir/output.h264")" -eq 10
cat > "$adapter_test_dir/client.log" <<'EOF_SESSION_STATS'
dawnshell-codec: session-stats={"session_id":7,"kind":"surface_transcoder","input_codec":"OMX.Exynos.avc.dec","output_codec":"OMX.Exynos.AVC.Encoder","transport":"surface_zero_copy","input_frames":2,"output_frames":2,"surface_frames":2,"cpu_yuv_frames":0,"input_eos":1,"output_eos":1,"errors":0,"dropped_frames":0,"input_call_latency_samples":2,"input_call_latency_avg_us":100,"input_call_latency_max_us":150,"output_call_latency_samples":2,"output_call_latency_avg_us":200,"output_call_latency_max_us":300}
EOF_SESSION_STATS
python3 "$ffmpeg_adapter" validate-stats "$adapter_test_dir/client.log" 2 \
    | grep -Eq '^surface_zero_copy=verified frames=2 cpu_yuv_frames=0 runtime_ms='

cat > "$adapter_test_dir/decode-shared.log" <<'EOF_SHARED_STATS'
dawnshell-codec: session-stats={"session_id":8,"kind":"bytebuffer_decoder","transport":"bytebuffer","media_transport":"mixed","input_frames":2,"output_frames":2,"cpu_yuv_frames":2,"socket_input_bytes":10,"socket_output_bytes":0,"shared_input_bytes":0,"shared_output_bytes":48,"input_eos":1,"output_eos":1,"errors":0,"uptime_ms":10,"process_cpu_time_ms":4,"input_call_latency_samples":2,"input_call_latency_avg_us":100,"input_call_latency_max_us":150,"output_call_latency_samples":2,"output_call_latency_avg_us":200,"output_call_latency_max_us":300}
EOF_SHARED_STATS
cat > "$adapter_test_dir/decode-socket.log" <<'EOF_SOCKET_STATS'
dawnshell-codec: session-stats={"session_id":9,"kind":"bytebuffer_decoder","transport":"bytebuffer","media_transport":"socket","input_frames":2,"output_frames":2,"cpu_yuv_frames":2,"socket_input_bytes":10,"socket_output_bytes":48,"shared_input_bytes":0,"shared_output_bytes":0,"input_eos":1,"output_eos":1,"errors":0,"uptime_ms":12,"process_cpu_time_ms":6,"input_call_latency_samples":2,"input_call_latency_avg_us":110,"input_call_latency_max_us":160,"output_call_latency_samples":2,"output_call_latency_avg_us":210,"output_call_latency_max_us":310}
EOF_SOCKET_STATS
python3 "$ffmpeg_adapter" compare-decode-transports \
    "$adapter_test_dir/decode-shared.log" "$adapter_test_dir/decode-socket.log" 2 \
    | grep -Fq 'decode_transport_comparison=verified frames=2'
python3 "$ffmpeg_adapter" validate-decoder-stats \
    "$adapter_test_dir/decode-shared.log" 2 \
    | grep -Fq 'hardware_decode_statistics=verified frames=2'
cat > "$adapter_test_dir/encode.log" <<'EOF_ENCODER_STATS'
dawnshell-codec: session-stats={"session_id":10,"kind":"bytebuffer_encoder","transport":"bytebuffer","input_frames":2,"output_frames":2,"output_bytes":12500,"input_eos":1,"output_eos":1,"errors":0,"dropped_frames":0,"input_call_latency_samples":2,"input_call_latency_avg_us":120,"input_call_latency_max_us":170,"output_call_latency_samples":2,"output_call_latency_avg_us":220,"output_call_latency_max_us":320}
EOF_ENCODER_STATS
python3 "$ffmpeg_adapter" validate-encoder-stats \
    "$adapter_test_dir/encode.log" 2 25 1000000 \
    --output "$adapter_test_dir/encoder-metrics.json" \
    | grep -Fq 'hardware_encode_statistics=verified frames=2 actual_bitrate_bps=1250000'
grep -Fq '"target_ratio": 1.25' "$adapter_test_dir/encoder-metrics.json"
printf '%s\n' '{"broker_state":"listening","pid":77,"uptime_ms":100,"active_sessions":0,"active_transcoders":0,"sessions_created":3,"sessions_closed":3}' \
    > "$adapter_test_dir/health-before.json"
printf '%s\n' '{"broker_state":"listening","pid":77,"uptime_ms":200,"active_sessions":0,"active_transcoders":0,"sessions_created":13,"sessions_closed":13}' \
    > "$adapter_test_dir/health-after.json"
python3 "$ffmpeg_adapter" validate-cleanup "$adapter_test_dir/health-before.json" \
    "$adapter_test_dir/health-after.json" 10 \
    | grep -Fqx 'codec_resource_cleanup=verified sessions=10 active_sessions=0 active_transcoders=0'
python3 "$ffmpeg_adapter" validate-balanced-health \
    "$adapter_test_dir/health-before.json" "$adapter_test_dir/health-after.json" 9 \
    | grep -Fq 'codec_error_isolation=verified sessions=10'
printf '%s\n' '{"broker_state":"listening","pid":77,"uptime_ms":150,"active_sessions":2,"active_transcoders":1,"sessions_created":5,"sessions_closed":3}' \
    > "$adapter_test_dir/health-overlap.json"
python3 "$ffmpeg_adapter" validate-concurrency-health \
    "$adapter_test_dir/health-overlap.json" 2 1 \
    | grep -Fqx 'codec_concurrency=verified active_sessions=2 active_transcoders=1'
cat > "$adapter_test_dir/health.jsonl" <<'EOF_HEALTH_SAMPLES'
{"broker_state":"listening","pid":77,"uptime_ms":100,"active_sessions":0,"active_transcoders":0,"sessions_created":3,"sessions_closed":3,"process_rss_kb":10000,"open_fd_count":20,"java_heap_used_bytes":1000000,"process_cpu_time_ms":500,"thermal_status":1,"battery_temperature_deci_c":320,"user_unlocked":false,"input_records":10,"output_records":10,"input_bytes":1000,"output_bytes":2000,"input_dequeue_timeouts":1,"output_dequeue_timeouts":2,"queue_depth_high_water":1,"peak_input_payload_bytes":100,"peak_output_payload_bytes":200}
{"broker_state":"listening","pid":77,"uptime_ms":200,"active_sessions":0,"active_transcoders":0,"sessions_created":14,"sessions_closed":14,"process_rss_kb":11000,"open_fd_count":21,"java_heap_used_bytes":1200000,"process_cpu_time_ms":900,"thermal_status":2,"battery_temperature_deci_c":350,"user_unlocked":true,"input_records":30,"output_records":30,"input_bytes":5000,"output_bytes":9000,"input_dequeue_timeouts":3,"output_dequeue_timeouts":7,"queue_depth_high_water":1,"peak_input_payload_bytes":150,"peak_output_payload_bytes":300}
EOF_HEALTH_SAMPLES
python3 "$ffmpeg_adapter" summarize-health "$adapter_test_dir/health.jsonl" \
    "$adapter_test_dir/health-summary.json" \
    | grep -Fq 'codec_health_stability=verified samples=2 pid=77'
grep -Fq '"rss_growth_kb": 1000' "$adapter_test_dir/health-summary.json"
grep -Fq '"fd_growth": 1' "$adapter_test_dir/health-summary.json"
grep -Fq '"input_dequeue_timeouts_delta": 2' \
    "$adapter_test_dir/health-summary.json"
grep -Fq '"queue_depth_high_water": 1' \
    "$adapter_test_dir/health-summary.json"

cat > "$adapter_test_dir/psnr.log" <<'EOF_PSNR'
[Parsed_psnr_0 @ 0x1] PSNR y:44.000 u:43.000 v:42.000 average:43.250 min:40.000 max:45.000
EOF_PSNR
cat > "$adapter_test_dir/ssim.log" <<'EOF_SSIM'
[Parsed_ssim_0 @ 0x1] SSIM Y:0.995000 U:0.994000 V:0.993000 All:0.994500 (22.596373)
EOF_SSIM
python3 "$ffmpeg_adapter" validate-quality "$adapter_test_dir/psnr.log" \
    "$adapter_test_dir/ssim.log" 30 0.90 \
    --output "$adapter_test_dir/quality.json" \
    | grep -Fqx 'codec_quality=verified average_psnr_db=43.2500 ssim_all=0.994500'
grep -Fq '"average_psnr_db": 43.25' "$adapter_test_dir/quality.json"

printf '%s\n' \
    '{"broker_state":"listening","pid":77,"process_cpu_time_ms":1000}' \
    > "$adapter_test_dir/baseline-before.json"
printf '%s\n' \
    '{"broker_state":"listening","pid":77,"process_cpu_time_ms":1100}' \
    > "$adapter_test_dir/baseline-after.json"
cat > "$adapter_test_dir/hardware.time" <<'EOF_HARDWARE_TIME'
wall_seconds=0.5
user_seconds=0.1
system_seconds=0.1
max_rss_kb=2048
EOF_HARDWARE_TIME
cat > "$adapter_test_dir/software.time" <<'EOF_SOFTWARE_TIME'
wall_seconds=1.0
user_seconds=0.7
system_seconds=0.2
max_rss_kb=4096
EOF_SOFTWARE_TIME
python3 "$ffmpeg_adapter" compare-cpu-baseline \
    "$adapter_test_dir/baseline-before.json" \
    "$adapter_test_dir/baseline-after.json" \
    "$adapter_test_dir/hardware.time" "$adapter_test_dir/software.time" \
    "$adapter_test_dir/cpu-baseline.json" \
    | grep -Fq 'codec_cpu_baseline=recorded'
grep -Fq '"cpu_reduction_percent": 66.666' \
    "$adapter_test_dir/cpu-baseline.json"

cat > "$adapter_test_dir/client-time.tsv" <<'EOF_CLIENT_TIME'
iteration=1 wall_seconds=1.0 user_seconds=0.2 system_seconds=0.1 max_rss_kb=3000
iteration=2 wall_seconds=1.1 user_seconds=0.3 system_seconds=0.1 max_rss_kb=3200
EOF_CLIENT_TIME
python3 "$ffmpeg_adapter" summarize-time-series \
    "$adapter_test_dir/client-time.tsv" \
    "$adapter_test_dir/client-time-summary.json" 4 \
    | grep -Fq 'codec_client_time=recorded samples=2'
grep -Fq '"client_cpu_seconds_total": 0.7' \
    "$adapter_test_dir/client-time-summary.json"

python3 - "$adapter_test_dir/synthetic-hevc.records" <<'PYTHON_SYNTHETIC_HEVC'
import pathlib
import struct
import sys

record = struct.Struct(">QII")
start = b"\x00\x00\x00\x01"
payload = b"".join(
    start + bytes((nal_type << 1, 1)) + bytes((0x55,)) * 32
    for nal_type in (32, 33, 34, 19)
)
second = start + bytes((1 << 1, 1)) + bytes((0x66,)) * 32
pathlib.Path(sys.argv[1]).write_bytes(
    record.pack(0, 0, len(payload)) + payload
    + record.pack(33_333, 0, len(second)) + second
)
PYTHON_SYNTHETIC_HEVC
awk '/^python3 - .*PY_ERROR_VECTORS/{capture=1; next}
     /^PY_ERROR_VECTORS$/{if (capture) exit}
     capture' "$error_test" > "$adapter_test_dir/error-vectors.py"
python3 "$adapter_test_dir/error-vectors.py" "$vector_720" \
    "$adapter_test_dir" "$adapter_test_dir/synthetic-hevc.records"
test -s "$adapter_test_dir/missing-hevc-config.records"
test -s "$adapter_test_dir/truncated-hevc.records"

# The committed launcher must stay dynamically linked against Android's
# linker. A static-pie launcher segfaults immediately on the device,
# while the codec client must stay static so Debian can run it directly.
python3 - "$repo_dir" <<'PYTHON_VERIFY_LINKAGE'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / "app/src/main/assets/bfu/bin"
interpreters = {
    "arm64-v8a": b"/system/bin/linker64",
    "armeabi-v7a": b"/system/bin/linker",
    "x86_64": b"/system/bin/linker64",
}
for abi, interpreter in interpreters.items():
    launcher = (root / abi / "bfu-namespace-probe").read_bytes()
    if interpreter not in launcher:
        raise SystemExit(
            f"{abi} launcher must be dynamically linked against {interpreter.decode()}"
        )
    client = (root / abi / "dawnshell-codec").read_bytes()
    if b"/system/bin/linker" in client:
        raise SystemExit(f"{abi} codec client must stay statically linked")
print("launcher is dynamically linked and codec client is static for all ABIs")
PYTHON_VERIFY_LINKAGE

echo "Hardware codec broker protocol, client, and three-ABI assets are pinned"
