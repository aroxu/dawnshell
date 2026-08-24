#!/usr/bin/python3
"""Packet framing adapter between FFprobe JSON and dawnshell-codec v1."""

import argparse
import decimal
import json
import pathlib
import struct
import sys

MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024
RECORD = struct.Struct(">QII")
EOS_FLAG = 4
CODEC_CONFIG_FLAG = 2


def load_packets(path):
    with open(path, "r", encoding="utf-8") as source:
        value = json.load(source)
    packets = value.get("packets")
    if not isinstance(packets, list):
        raise ValueError("FFprobe JSON has no packet list")
    return packets


def packet_pts(packet, index, frame_rate):
    value = packet.get("pts_time")
    if value in (None, "N/A"):
        value = packet.get("dts_time")
    if value not in (None, "N/A"):
        return int(decimal.Decimal(str(value)) * 1_000_000)
    numerator, denominator = frame_rate.split("/", 1)
    rate = decimal.Decimal(numerator) / decimal.Decimal(denominator)
    return int(decimal.Decimal(index) * decimal.Decimal(1_000_000) / rate)


def pack(arguments):
    input_packets = load_packets(arguments.input_packets)
    raw_packets = load_packets(arguments.raw_packets)
    if not input_packets or len(input_packets) != len(raw_packets):
        raise ValueError(
            "input and Annex-B packet counts differ: "
            f"{len(input_packets)} != {len(raw_packets)}"
        )
    raw_path = pathlib.Path(arguments.annex_b)
    raw_size = raw_path.stat().st_size
    pts_values = [
        packet_pts(packet, index, arguments.frame_rate)
        for index, packet in enumerate(input_packets)
    ]
    shift = min(pts_values)
    with raw_path.open("rb") as raw, open(arguments.output, "wb") as output:
        for index, packet in enumerate(raw_packets):
            position = int(packet.get("pos", -1))
            size = int(packet.get("size", -1))
            if position < 0 or size <= 0 or size > MAX_MEDIA_PAYLOAD - RECORD.size:
                raise ValueError(f"invalid Annex-B packet at index {index}")
            if position + size > raw_size:
                raise ValueError(f"Annex-B packet exceeds file at index {index}")
            raw.seek(position)
            data = raw.read(size)
            if len(data) != size:
                raise ValueError(f"short Annex-B packet at index {index}")
            pts = pts_values[index] - shift
            if pts < 0:
                raise ValueError("normalized packet PTS became negative")
            output.write(RECORD.pack(pts, 0, size))
            output.write(data)
    print(f"packed_packets={len(raw_packets)} pts_shift_us={shift}")


def unpack(arguments):
    frame_size = arguments.width * arguments.height * 3 // 2
    if frame_size <= 0 or frame_size > MAX_MEDIA_PAYLOAD - RECORD.size:
        raise ValueError("invalid decoded I420 frame size")
    frames = 0
    previous_pts = -1
    with open(arguments.input, "rb") as source, open(arguments.output, "wb") as output:
        while True:
            header = source.read(RECORD.size)
            if not header:
                break
            if len(header) != RECORD.size:
                raise ValueError("truncated decoded record header")
            pts, flags, size = RECORD.unpack(header)
            if size > MAX_MEDIA_PAYLOAD - RECORD.size:
                raise ValueError("decoded record exceeds protocol limit")
            data = source.read(size)
            if len(data) != size:
                raise ValueError("truncated decoded record payload")
            if size:
                if size != frame_size:
                    raise ValueError(
                        f"decoded frame {frames} has {size} bytes; expected {frame_size}"
                    )
                if pts < previous_pts:
                    raise ValueError("decoded PTS is not monotonic")
                previous_pts = pts
                output.write(data)
                frames += 1
            if flags & EOS_FLAG:
                break
    if frames == 0:
        raise ValueError("hardware decoder produced no frames")
    print(frames)


def parse_rate(value):
    numerator, denominator = value.split("/", 1)
    rate = decimal.Decimal(numerator) / decimal.Decimal(denominator)
    if rate < 1 or rate > 240:
        raise ValueError("frame rate must be within 1..240")
    return rate


def pack_i420(arguments):
    frame_size = arguments.width * arguments.height * 3 // 2
    if frame_size <= 0 or frame_size > MAX_MEDIA_PAYLOAD - RECORD.size:
        raise ValueError("invalid I420 frame size")
    rate = parse_rate(arguments.frame_rate)
    raw_size = pathlib.Path(arguments.input).stat().st_size
    if raw_size == 0 or raw_size % frame_size != 0:
        raise ValueError("raw I420 input is not an exact number of frames")
    frames = raw_size // frame_size
    with open(arguments.input, "rb") as source, open(arguments.output, "wb") as output:
        for index in range(frames):
            frame = source.read(frame_size)
            if len(frame) != frame_size:
                raise ValueError("short I420 frame")
            pts = int(decimal.Decimal(index) * decimal.Decimal(1_000_000) / rate)
            output.write(RECORD.pack(pts, 0, frame_size))
            output.write(frame)
    print(frames)


def unpack_annex_b(arguments):
    frames = 0
    previous_pts = -1
    first_frame_is_key = False
    with open(arguments.input, "rb") as source, open(arguments.output, "wb") as output:
        while True:
            header = source.read(RECORD.size)
            if not header:
                break
            if len(header) != RECORD.size:
                raise ValueError("truncated encoded record header")
            pts, flags, size = RECORD.unpack(header)
            if size > MAX_MEDIA_PAYLOAD - RECORD.size:
                raise ValueError("encoded record exceeds protocol limit")
            data = source.read(size)
            if len(data) != size:
                raise ValueError("truncated encoded record payload")
            if size:
                output.write(data)
                if not flags & CODEC_CONFIG_FLAG:
                    if frames == 0:
                        first_frame_is_key = bool(flags & 1)
                    if pts < previous_pts:
                        raise ValueError("encoded PTS is not monotonic")
                    previous_pts = pts
                    frames += 1
            if flags & EOS_FLAG:
                break
    if frames == 0:
        raise ValueError("hardware encoder produced no frames")
    if arguments.require_keyframe and not first_frame_is_key:
        raise ValueError("first hardware-encoded frame is not a keyframe")
    print(frames)


def load_last_stats(path):
    prefix = "dawnshell-codec: session-stats="
    stats = None
    with open(path, "r", encoding="utf-8", errors="replace") as source:
        for line in source:
            if line.startswith(prefix):
                stats = json.loads(line[len(prefix):])
    if not isinstance(stats, dict):
        raise ValueError("client log has no session statistics")
    return stats


def validate_stats(arguments):
    stats = load_last_stats(arguments.input)
    expected = arguments.frames
    checks = {
        "kind": "surface_transcoder",
        "transport": "surface_zero_copy",
        "input_frames": expected,
        "output_frames": expected,
        "surface_frames": expected,
        "cpu_yuv_frames": 0,
        "errors": 0,
        "dropped_frames": 0,
    }
    for key, expected_value in checks.items():
        if stats.get(key) != expected_value:
            raise ValueError(
                f"session statistic {key}={stats.get(key)!r}; expected {expected_value!r}"
            )
    if int(stats.get("input_eos", 0)) < 1 or int(stats.get("output_eos", 0)) < 1:
        raise ValueError("transcoder statistics do not prove EOS completion")
    if arguments.max_runtime_ms is not None:
        runtime_ms = int(stats.get("uptime_ms", -1))
        if runtime_ms < 0 or runtime_ms > arguments.max_runtime_ms:
            raise ValueError(
                f"transcoder runtime {runtime_ms}ms exceeds "
                f"{arguments.max_runtime_ms}ms media duration"
            )
    print(
        "surface_zero_copy=verified "
        f"frames={expected} cpu_yuv_frames=0 runtime_ms={stats.get('uptime_ms')} "
        f"process_cpu_time_ms={stats.get('process_cpu_time_ms')} "
        f"session_id={stats.get('session_id')}"
    )


def compare_decode_transports(arguments):
    shared = load_last_stats(arguments.shared_log)
    socket = load_last_stats(arguments.socket_log)
    for label, stats in (("shared", shared), ("socket", socket)):
        if stats.get("kind") != "bytebuffer_decoder":
            raise ValueError(f"{label} run is not a decoder session")
        for key in ("input_frames", "output_frames", "cpu_yuv_frames"):
            if int(stats.get(key, -1)) != arguments.frames:
                raise ValueError(
                    f"{label} run {key}={stats.get(key)!r}; expected {arguments.frames}"
                )
        if int(stats.get("input_eos", 0)) < 1 or int(stats.get("output_eos", 0)) < 1:
            raise ValueError(f"{label} run did not complete EOS")
        if int(stats.get("errors", -1)) != 0:
            raise ValueError(f"{label} run recorded codec errors")
    if int(shared.get("shared_output_bytes", 0)) <= 0:
        raise ValueError("default decoder run did not use shared-memory output")
    if shared.get("media_transport") not in ("shared_memory", "mixed"):
        raise ValueError("default decoder run did not report shared-memory transport")
    if int(socket.get("shared_input_bytes", -1)) != 0 \
            or int(socket.get("shared_output_bytes", -1)) != 0:
        raise ValueError("socket fallback run unexpectedly used shared memory")
    if int(socket.get("socket_output_bytes", 0)) <= 0:
        raise ValueError("socket fallback run did not transfer decoder output")
    if socket.get("media_transport") != "socket":
        raise ValueError("socket fallback run did not report socket transport")
    print(
        "decode_transport_comparison=verified "
        f"frames={arguments.frames} "
        f"shared_runtime_ms={shared.get('uptime_ms')} "
        f"shared_process_cpu_ms={shared.get('process_cpu_time_ms')} "
        f"socket_runtime_ms={socket.get('uptime_ms')} "
        f"socket_process_cpu_ms={socket.get('process_cpu_time_ms')}"
    )


def load_health(path):
    with open(path, "r", encoding="utf-8", errors="strict") as source:
        value = json.load(source)
    if not isinstance(value, dict) or value.get("broker_state") != "listening":
        raise ValueError(f"invalid broker health snapshot: {path}")
    return value


def validate_cleanup(arguments):
    before = load_health(arguments.before)
    after = load_health(arguments.after)
    for label, health in (("before", before), ("after", after)):
        if int(health.get("active_sessions", -1)) != 0 \
                or int(health.get("active_transcoders", -1)) != 0:
            raise ValueError(f"{label} snapshot has active codec resources")
        if int(health.get("sessions_created", -1)) \
                != int(health.get("sessions_closed", -2)):
            raise ValueError(f"{label} snapshot has an unclosed session")
    if int(after.get("uptime_ms", -1)) < int(before.get("uptime_ms", 0)):
        raise ValueError("codec broker restarted during resource cleanup test")
    created_delta = int(after["sessions_created"]) - int(before["sessions_created"])
    closed_delta = int(after["sessions_closed"]) - int(before["sessions_closed"])
    if created_delta != arguments.sessions or closed_delta != arguments.sessions:
        raise ValueError(
            f"cleanup delta created={created_delta} closed={closed_delta}; "
            f"expected {arguments.sessions}"
        )
    print(
        "codec_resource_cleanup=verified "
        f"sessions={arguments.sessions} active_sessions=0 active_transcoders=0"
    )


def positive_int(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    pack_parser = commands.add_parser("pack")
    pack_parser.add_argument("input_packets")
    pack_parser.add_argument("raw_packets")
    pack_parser.add_argument("annex_b")
    pack_parser.add_argument("frame_rate")
    pack_parser.add_argument("output")
    pack_parser.set_defaults(handler=pack)
    unpack_parser = commands.add_parser("unpack")
    unpack_parser.add_argument("input")
    unpack_parser.add_argument("output")
    unpack_parser.add_argument("width", type=positive_int)
    unpack_parser.add_argument("height", type=positive_int)
    unpack_parser.set_defaults(handler=unpack)
    pack_i420_parser = commands.add_parser("pack-i420")
    pack_i420_parser.add_argument("input")
    pack_i420_parser.add_argument("width", type=positive_int)
    pack_i420_parser.add_argument("height", type=positive_int)
    pack_i420_parser.add_argument("frame_rate")
    pack_i420_parser.add_argument("output")
    pack_i420_parser.set_defaults(handler=pack_i420)
    unpack_annex_b_parser = commands.add_parser("unpack-annexb")
    unpack_annex_b_parser.add_argument("input")
    unpack_annex_b_parser.add_argument("output")
    unpack_annex_b_parser.add_argument("--require-keyframe", action="store_true")
    unpack_annex_b_parser.set_defaults(handler=unpack_annex_b)
    validate_stats_parser = commands.add_parser("validate-stats")
    validate_stats_parser.add_argument("input")
    validate_stats_parser.add_argument("frames", type=positive_int)
    validate_stats_parser.add_argument("--max-runtime-ms", type=positive_int)
    validate_stats_parser.set_defaults(handler=validate_stats)
    compare_transport_parser = commands.add_parser("compare-decode-transports")
    compare_transport_parser.add_argument("shared_log")
    compare_transport_parser.add_argument("socket_log")
    compare_transport_parser.add_argument("frames", type=positive_int)
    compare_transport_parser.set_defaults(handler=compare_decode_transports)
    cleanup_parser = commands.add_parser("validate-cleanup")
    cleanup_parser.add_argument("before")
    cleanup_parser.add_argument("after")
    cleanup_parser.add_argument("sessions", type=positive_int)
    cleanup_parser.set_defaults(handler=validate_cleanup)
    arguments = parser.parse_args()
    try:
        arguments.handler(arguments)
    except (OSError, ValueError, decimal.InvalidOperation, ZeroDivisionError) as error:
        print(f"dawnshell-codec-ffmpeg: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
