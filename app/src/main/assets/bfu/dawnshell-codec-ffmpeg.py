#!/usr/bin/python3
"""Packet framing adapter between FFprobe JSON and dawnshell-codec v1."""

import argparse
import contextlib
import decimal
import json
import math
import pathlib
import re
import struct
import sys

MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024
RECORD = struct.Struct(">QII")
EOS_FLAG = 4
CODEC_CONFIG_FLAG = 2


def binary_input(path):
    return contextlib.nullcontext(sys.stdin.buffer) if path == "-" else open(path, "rb")


def binary_output(path):
    return contextlib.nullcontext(sys.stdout.buffer) if path == "-" else open(path, "wb")


def report_count(label, count, binary_output_path):
    if binary_output_path == "-":
        print(f"{label}={count}", file=sys.stderr)
    else:
        print(count)


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
    with binary_input(arguments.input) as source, binary_output(arguments.output) as output:
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
    report_count("unpacked_i420_frames", frames, arguments.output)


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
    frames = 0
    with binary_input(arguments.input) as source, binary_output(arguments.output) as output:
        while True:
            frame = source.read(frame_size)
            if not frame:
                break
            if len(frame) != frame_size:
                raise ValueError("raw I420 input ends with a partial frame")
            pts = int(decimal.Decimal(frames) * decimal.Decimal(1_000_000) / rate)
            output.write(RECORD.pack(pts, 0, frame_size))
            output.write(frame)
            frames += 1
    if frames == 0:
        raise ValueError("raw I420 input has no complete frames")
    report_count("packed_i420_frames", frames, arguments.output)


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


def require_call_latency(stats, label):
    for direction in ("input", "output"):
        samples = int(stats.get(f"{direction}_call_latency_samples", -1))
        average = int(stats.get(f"{direction}_call_latency_avg_us", -1))
        maximum = int(stats.get(f"{direction}_call_latency_max_us", -1))
        if samples <= 0 or average < 0 or maximum < 0 or average > maximum:
            raise ValueError(
                f"{label} has invalid {direction} call latency metrics: "
                f"samples={samples} average_us={average} max_us={maximum}"
            )


def validate_stats(arguments):
    stats = load_last_stats(arguments.input)
    require_call_latency(stats, "transcoder")
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
        require_call_latency(stats, f"{label} decoder")
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


def validate_decoder_stats(arguments):
    stats = load_last_stats(arguments.input)
    require_call_latency(stats, "decoder")
    if stats.get("kind") != "bytebuffer_decoder":
        raise ValueError("session is not a bytebuffer decoder")
    for key in ("input_frames", "output_frames", "cpu_yuv_frames"):
        if int(stats.get(key, -1)) != arguments.frames:
            raise ValueError(
                f"decoder {key}={stats.get(key)!r}; expected {arguments.frames}"
            )
    if int(stats.get("input_eos", 0)) < 1 or int(stats.get("output_eos", 0)) < 1:
        raise ValueError("decoder statistics do not prove EOS completion")
    if int(stats.get("errors", -1)) != 0:
        raise ValueError("decoder session recorded codec errors")
    if stats.get("media_transport") not in ("shared_memory", "mixed"):
        raise ValueError("decoder did not use shared-memory media output")
    print(
        "hardware_decode_statistics=verified "
        f"frames={arguments.frames} transport={stats.get('media_transport')} "
        f"runtime_ms={stats.get('uptime_ms')} "
        f"process_cpu_time_ms={stats.get('process_cpu_time_ms')}"
    )


def validate_encoder_stats(arguments):
    stats = load_last_stats(arguments.input)
    require_call_latency(stats, "encoder")
    if stats.get("kind") != "bytebuffer_encoder":
        raise ValueError("session is not a bytebuffer encoder")
    for key in ("input_frames", "output_frames"):
        if int(stats.get(key, -1)) != arguments.frames:
            raise ValueError(
                f"encoder {key}={stats.get(key)!r}; expected {arguments.frames}"
            )
    if int(stats.get("input_eos", 0)) < 1 or int(stats.get("output_eos", 0)) < 1:
        raise ValueError("encoder statistics do not prove EOS completion")
    if int(stats.get("errors", -1)) != 0 \
            or int(stats.get("dropped_frames", -1)) != 0:
        raise ValueError("encoder statistics report an error or dropped frame")
    output_bytes = int(stats.get("output_bytes", 0))
    if output_bytes <= 0:
        raise ValueError("encoder produced no compressed bytes")
    actual_bitrate = output_bytes * 8 * arguments.frame_rate / arguments.frames
    target_ratio = actual_bitrate / arguments.target_bitrate
    result = {
        "format": "dawnshell-codec-encoder-metrics-1",
        "frames": arguments.frames,
        "frame_rate": arguments.frame_rate,
        "target_bitrate_bps": arguments.target_bitrate,
        "actual_bitrate_bps": round(actual_bitrate),
        "target_ratio": target_ratio,
        "output_bytes": output_bytes,
        "input_call_latency_avg_us": int(stats["input_call_latency_avg_us"]),
        "input_call_latency_max_us": int(stats["input_call_latency_max_us"]),
        "output_call_latency_avg_us": int(stats["output_call_latency_avg_us"]),
        "output_call_latency_max_us": int(stats["output_call_latency_max_us"]),
    }
    if arguments.output:
        with open(arguments.output, "w", encoding="utf-8") as output:
            json.dump(result, output, sort_keys=True, indent=2)
            output.write("\n")
    print(
        "hardware_encode_statistics=verified "
        f"frames={arguments.frames} actual_bitrate_bps={result['actual_bitrate_bps']} "
        f"target_bitrate_bps={arguments.target_bitrate} "
        f"target_ratio={target_ratio:.4f} "
        f"input_latency_avg_us={result['input_call_latency_avg_us']} "
        f"input_latency_max_us={result['input_call_latency_max_us']} "
        f"output_latency_avg_us={result['output_call_latency_avg_us']} "
        f"output_latency_max_us={result['output_call_latency_max_us']}"
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


def summarize_health(arguments):
    samples = []
    with open(arguments.input, "r", encoding="utf-8", errors="strict") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict) or value.get("broker_state") != "listening":
                raise ValueError(f"invalid health sample at line {line_number}")
            samples.append(value)
    if len(samples) < 2:
        raise ValueError("at least two broker health samples are required")
    pids = {int(sample.get("pid", -1)) for sample in samples}
    if len(pids) != 1 or next(iter(pids)) <= 0:
        raise ValueError(f"broker PID changed during test: {sorted(pids)}")
    previous_uptime = -1
    for index, sample in enumerate(samples):
        uptime = int(sample.get("uptime_ms", -1))
        if uptime < previous_uptime:
            raise ValueError(f"broker uptime moved backwards at sample {index}")
        previous_uptime = uptime
        if int(sample.get("active_sessions", -1)) != 0 \
                or int(sample.get("active_transcoders", -1)) != 0:
            raise ValueError(f"health sample {index} has active codec resources")
        if int(sample.get("sessions_created", -1)) \
                != int(sample.get("sessions_closed", -2)):
            raise ValueError(f"health sample {index} has an unclosed session")

    def values(key):
        return [int(sample.get(key, -1)) for sample in samples]

    rss = values("process_rss_kb")
    descriptors = values("open_fd_count")
    heap = values("java_heap_used_bytes")
    cpu = values("process_cpu_time_ms")
    input_records = values("input_records")
    output_records = values("output_records")
    input_bytes = values("input_bytes")
    output_bytes = values("output_bytes")
    input_timeouts = values("input_dequeue_timeouts")
    output_timeouts = values("output_dequeue_timeouts")
    queue_depth = values("queue_depth_high_water")
    peak_input_payload = values("peak_input_payload_bytes")
    peak_output_payload = values("peak_output_payload_bytes")
    if min(rss + descriptors + heap + cpu) < 0:
        raise ValueError("health samples are missing process resource metrics")
    cumulative = (
        input_records + output_records + input_bytes + output_bytes
        + input_timeouts + output_timeouts + queue_depth
        + peak_input_payload + peak_output_payload
    )
    if min(cumulative) < 0:
        raise ValueError("health samples are missing queue and payload metrics")
    for name, series in (
        ("input_records", input_records),
        ("output_records", output_records),
        ("input_bytes", input_bytes),
        ("output_bytes", output_bytes),
        ("input_dequeue_timeouts", input_timeouts),
        ("output_dequeue_timeouts", output_timeouts),
        ("queue_depth_high_water", queue_depth),
        ("peak_input_payload_bytes", peak_input_payload),
        ("peak_output_payload_bytes", peak_output_payload),
    ):
        if any(current < previous for previous, current in zip(series, series[1:])):
            raise ValueError(f"cumulative health metric moved backwards: {name}")
    fd_growth = descriptors[-1] - descriptors[0]
    rss_growth = rss[-1] - rss[0]
    heap_growth = heap[-1] - heap[0]
    if fd_growth > arguments.max_fd_growth:
        raise ValueError(
            f"broker descriptor growth {fd_growth} exceeds {arguments.max_fd_growth}"
        )
    if rss_growth > arguments.max_rss_growth_kb:
        raise ValueError(
            f"broker RSS growth {rss_growth} KiB exceeds "
            f"{arguments.max_rss_growth_kb} KiB"
        )
    if heap_growth > arguments.max_heap_growth_bytes:
        raise ValueError(
            f"broker heap growth {heap_growth} bytes exceeds "
            f"{arguments.max_heap_growth_bytes} bytes"
        )
    summary = {
        "format": "dawnshell-codec-health-summary-1",
        "samples": len(samples),
        "pid": next(iter(pids)),
        "uptime_start_ms": int(samples[0]["uptime_ms"]),
        "uptime_end_ms": int(samples[-1]["uptime_ms"]),
        "cpu_delta_ms": cpu[-1] - cpu[0],
        "rss_start_kb": rss[0],
        "rss_end_kb": rss[-1],
        "rss_max_kb": max(rss),
        "rss_growth_kb": rss_growth,
        "fd_start": descriptors[0],
        "fd_end": descriptors[-1],
        "fd_max": max(descriptors),
        "fd_growth": fd_growth,
        "heap_start_bytes": heap[0],
        "heap_end_bytes": heap[-1],
        "heap_max_bytes": max(heap),
        "heap_growth_bytes": heap_growth,
        "thermal_max": max(values("thermal_status")),
        "battery_temperature_max_deci_c": max(
            values("battery_temperature_deci_c")
        ),
        "input_records_delta": input_records[-1] - input_records[0],
        "output_records_delta": output_records[-1] - output_records[0],
        "input_bytes_delta": input_bytes[-1] - input_bytes[0],
        "output_bytes_delta": output_bytes[-1] - output_bytes[0],
        "input_dequeue_timeouts_delta": input_timeouts[-1] - input_timeouts[0],
        "output_dequeue_timeouts_delta": output_timeouts[-1] - output_timeouts[0],
        "queue_depth_high_water": max(queue_depth),
        "peak_input_payload_bytes": max(peak_input_payload),
        "peak_output_payload_bytes": max(peak_output_payload),
        "user_unlocked_start": bool(samples[0].get("user_unlocked")),
        "user_unlocked_end": bool(samples[-1].get("user_unlocked")),
    }
    with open(arguments.output, "w", encoding="utf-8") as output:
        json.dump(summary, output, sort_keys=True, indent=2)
        output.write("\n")
    print(
        "codec_health_stability=verified "
        f"samples={len(samples)} pid={summary['pid']} "
        f"rss_growth_kb={rss_growth} fd_growth={fd_growth} "
        f"heap_growth_bytes={heap_growth} thermal_max={summary['thermal_max']} "
        f"queue_depth_high_water={summary['queue_depth_high_water']} "
        f"input_timeouts={summary['input_dequeue_timeouts_delta']} "
        f"output_timeouts={summary['output_dequeue_timeouts_delta']}"
    )


def validate_concurrency_health(arguments):
    health = load_health(arguments.input)
    sessions = int(health.get("active_sessions", -1))
    transcoders = int(health.get("active_transcoders", -1))
    if sessions != arguments.sessions:
        raise ValueError(
            f"active concurrent sessions={sessions}; expected {arguments.sessions}"
        )
    if transcoders != arguments.transcoders:
        raise ValueError(
            f"active concurrent transcoders={transcoders}; "
            f"expected {arguments.transcoders}"
        )
    print(
        "codec_concurrency=verified "
        f"active_sessions={sessions} active_transcoders={transcoders}"
    )


def validate_balanced_health(arguments):
    before = load_health(arguments.before)
    after = load_health(arguments.after)
    if int(before.get("pid", -1)) != int(after.get("pid", -2)):
        raise ValueError("codec broker restarted during error-isolation test")
    if int(after.get("uptime_ms", -1)) < int(before.get("uptime_ms", 0)):
        raise ValueError("codec broker uptime moved backwards")
    if int(after.get("active_sessions", -1)) != 0 \
            or int(after.get("active_transcoders", -1)) != 0:
        raise ValueError("codec broker retained active resources")
    if int(after.get("sessions_created", -1)) \
            != int(after.get("sessions_closed", -2)):
        raise ValueError("codec broker retained an unclosed session")
    created_delta = int(after.get("sessions_created", 0)) \
        - int(before.get("sessions_created", 0))
    if created_delta < arguments.minimum_sessions:
        raise ValueError(
            f"only {created_delta} sessions were exercised; "
            f"expected at least {arguments.minimum_sessions}"
        )
    print(
        "codec_error_isolation=verified "
        f"sessions={created_delta} active_sessions=0 broker_pid={after.get('pid')}"
    )


def validate_quality(arguments):
    psnr_text = pathlib.Path(arguments.psnr_log).read_text(
        encoding="utf-8", errors="replace"
    )
    ssim_text = pathlib.Path(arguments.ssim_log).read_text(
        encoding="utf-8", errors="replace"
    )
    psnr_matches = re.findall(r"\baverage:([0-9]+(?:\.[0-9]+)?|inf)\b", psnr_text)
    ssim_matches = re.findall(r"\bAll:([0-9]+(?:\.[0-9]+)?)\b", ssim_text)
    if not psnr_matches or not ssim_matches:
        raise ValueError("FFmpeg PSNR/SSIM summary was not found")
    psnr = float(psnr_matches[-1])
    ssim = float(ssim_matches[-1])
    if psnr < arguments.minimum_psnr:
        raise ValueError(
            f"average PSNR {psnr:.4f} is below {arguments.minimum_psnr:.4f} dB"
        )
    if ssim < arguments.minimum_ssim:
        raise ValueError(
            f"SSIM {ssim:.6f} is below {arguments.minimum_ssim:.6f}"
        )
    result = {
        "format": "dawnshell-codec-quality-1",
        "average_psnr_db": None if math.isinf(psnr) else psnr,
        "average_psnr_infinite": math.isinf(psnr),
        "ssim_all": ssim,
        "minimum_psnr_db": arguments.minimum_psnr,
        "minimum_ssim": arguments.minimum_ssim,
    }
    if arguments.output:
        with open(arguments.output, "w", encoding="utf-8") as output:
            json.dump(result, output, sort_keys=True, indent=2, allow_nan=False)
            output.write("\n")
    print(
        "codec_quality=verified "
        f"average_psnr_db={psnr:.4f} ssim_all={ssim:.6f}"
    )


def load_time_metrics(path):
    result = {}
    with open(path, "r", encoding="utf-8", errors="strict") as source:
        for line in source:
            key, separator, value = line.strip().partition("=")
            if separator and key:
                result[key] = float(value)
    for key in ("wall_seconds", "user_seconds", "system_seconds", "max_rss_kb"):
        if key not in result or result[key] < 0:
            raise ValueError(f"time report is missing {key}: {path}")
    return result


def compare_cpu_baseline(arguments):
    before = load_health(arguments.before_health)
    after = load_health(arguments.after_health)
    if int(before.get("pid", -1)) != int(after.get("pid", -2)):
        raise ValueError("codec broker restarted during CPU comparison")
    broker_cpu_seconds = (
        int(after.get("process_cpu_time_ms", -1))
        - int(before.get("process_cpu_time_ms", -1))
    ) / 1000.0
    if broker_cpu_seconds < 0:
        raise ValueError("broker CPU time moved backwards")
    hardware = load_time_metrics(arguments.hardware_time)
    software = load_time_metrics(arguments.software_time)
    hardware_client_cpu = hardware["user_seconds"] + hardware["system_seconds"]
    hardware_total_cpu = hardware_client_cpu + broker_cpu_seconds
    software_total_cpu = software["user_seconds"] + software["system_seconds"]
    if software_total_cpu <= 0:
        raise ValueError("software baseline reported no CPU time")
    reduction = (software_total_cpu - hardware_total_cpu) * 100.0 / software_total_cpu
    if arguments.minimum_cpu_reduction_percent is not None \
            and reduction < arguments.minimum_cpu_reduction_percent:
        raise ValueError(
            f"hardware CPU reduction {reduction:.3f}% is below "
            f"{arguments.minimum_cpu_reduction_percent:.3f}%"
        )
    result = {
        "format": "dawnshell-codec-cpu-baseline-1",
        "hardware_wall_seconds": hardware["wall_seconds"],
        "hardware_client_cpu_seconds": hardware_client_cpu,
        "hardware_broker_cpu_seconds": broker_cpu_seconds,
        "hardware_total_cpu_seconds": hardware_total_cpu,
        "hardware_client_max_rss_kb": hardware["max_rss_kb"],
        "software_wall_seconds": software["wall_seconds"],
        "software_total_cpu_seconds": software_total_cpu,
        "software_max_rss_kb": software["max_rss_kb"],
        "cpu_reduction_percent": reduction,
        "threshold_enforced": arguments.minimum_cpu_reduction_percent is not None,
    }
    with open(arguments.output, "w", encoding="utf-8") as output:
        json.dump(result, output, sort_keys=True, indent=2)
        output.write("\n")
    print(
        "codec_cpu_baseline=recorded "
        f"hardware_total_cpu_seconds={hardware_total_cpu:.3f} "
        f"software_total_cpu_seconds={software_total_cpu:.3f} "
        f"cpu_reduction_percent={reduction:.3f} "
        f"threshold_enforced={str(result['threshold_enforced']).lower()}"
    )


def summarize_time_series(arguments):
    samples = []
    with open(arguments.input, "r", encoding="utf-8", errors="strict") as source:
        for line_number, line in enumerate(source, 1):
            fields = {}
            for token in line.split():
                key, separator, value = token.partition("=")
                if separator:
                    fields[key] = value
            try:
                sample = {
                    "iteration": int(fields["iteration"]),
                    "wall_seconds": float(fields["wall_seconds"]),
                    "user_seconds": float(fields["user_seconds"]),
                    "system_seconds": float(fields["system_seconds"]),
                    "max_rss_kb": float(fields["max_rss_kb"]),
                }
            except (KeyError, ValueError) as error:
                raise ValueError(
                    f"invalid GNU time sample at line {line_number}"
                ) from error
            if min(sample.values()) < 0:
                raise ValueError(f"negative GNU time metric at line {line_number}")
            samples.append(sample)
    if not samples:
        raise ValueError("GNU time series has no samples")
    expected_iterations = list(range(1, len(samples) + 1))
    if [sample["iteration"] for sample in samples] != expected_iterations:
        raise ValueError("GNU time iteration sequence is incomplete")
    user_total = sum(sample["user_seconds"] for sample in samples)
    system_total = sum(sample["system_seconds"] for sample in samples)
    wall_total = sum(sample["wall_seconds"] for sample in samples)
    client_cpu_total = user_total + system_total
    result = {
        "format": "dawnshell-codec-client-time-summary-1",
        "samples": len(samples),
        "processed_media_seconds": arguments.processed_media_seconds,
        "wall_seconds_total": wall_total,
        "user_seconds_total": user_total,
        "system_seconds_total": system_total,
        "client_cpu_seconds_total": client_cpu_total,
        "client_cpu_seconds_per_media_second": (
            client_cpu_total / arguments.processed_media_seconds
        ),
        "max_rss_kb": max(sample["max_rss_kb"] for sample in samples),
    }
    with open(arguments.output, "w", encoding="utf-8") as output:
        json.dump(result, output, sort_keys=True, indent=2)
        output.write("\n")
    print(
        "codec_client_time=recorded "
        f"samples={len(samples)} wall_seconds={wall_total:.3f} "
        f"cpu_seconds={client_cpu_total:.3f} "
        f"max_rss_kb={result['max_rss_kb']:.0f}"
    )


def positive_int(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


HARDWARE_ENCODERS = {
    "libx264": "avc",
    "h264": "avc",
    "libx265": "hevc",
    "hevc": "hevc",
}
RAW_VIDEO_SUFFIXES = (".i420", ".yuv")
# Options the bridge reproduces exactly. Anything else falls back to plain
# FFmpeg so a filter, scaler, or muxer flag is never silently dropped.
PASSTHROUGH_FLAGS = {"-hide_banner", "-y", "-n", "-an", "-nostdin"}
IGNORED_VALUE_OPTIONS = {"-loglevel", "-v", "-threads", "-stats_period",
                         "-pix_fmt", "-f", "-r"}


class UnsupportedCommand(Exception):
    """Raised when an FFmpeg command must fall back to plain software."""


def parse_bitrate(value):
    text = value.strip().lower()
    multiplier = 1
    if text.endswith("k"):
        multiplier = 1000
        text = text[:-1]
    elif text.endswith("m"):
        multiplier = 1000000
        text = text[:-1]
    if not text or not text.replace(".", "", 1).isdigit():
        raise UnsupportedCommand("unsupported_bitrate")
    parsed = int(float(text) * multiplier)
    if parsed < 1000 or parsed > 100000000:
        raise UnsupportedCommand("bitrate_out_of_range")
    return parsed


def parse_ffmpeg_command(argv):
    """Return a bridge plan for an FFmpeg command or raise UnsupportedCommand."""
    inputs = []
    output = None
    video_codec = None
    bitrate = None
    index = 0
    while index < len(argv):
        token = argv[index]
        if not token.startswith("-"):
            if output is not None:
                raise UnsupportedCommand("multiple_outputs")
            output = token
            index += 1
            continue
        if token in PASSTHROUGH_FLAGS:
            index += 1
            continue
        if index + 1 >= len(argv):
            raise UnsupportedCommand("missing_option_value")
        value = argv[index + 1]
        if token == "-i":
            inputs.append(value)
        elif token in ("-c:v", "-codec:v", "-vcodec"):
            video_codec = value
        elif token == "-b:v":
            bitrate = parse_bitrate(value)
        elif token == "-map":
            if value not in ("0:v:0", "0:v", "0"):
                raise UnsupportedCommand("unsupported_map")
        elif token not in IGNORED_VALUE_OPTIONS:
            raise UnsupportedCommand("unsupported_option")
        index += 2

    if len(inputs) != 1:
        raise UnsupportedCommand("requires_single_input")
    if output is None:
        raise UnsupportedCommand("missing_output")
    if video_codec == "copy":
        raise UnsupportedCommand("stream_copy")

    if video_codec is None:
        if pathlib.PurePath(output).suffix.lower() in RAW_VIDEO_SUFFIXES:
            return {"action": "decode", "input": inputs[0], "output": output}
        raise UnsupportedCommand("no_video_encoder")
    if video_codec not in HARDWARE_ENCODERS:
        raise UnsupportedCommand("unsupported_encoder")
    return {
        "action": "transcode",
        "input": inputs[0],
        "output": output,
        "codec": HARDWARE_ENCODERS[video_codec],
        "bitrate": bitrate,
    }


def plan_ffmpeg(argv):
    try:
        plan = parse_ffmpeg_command(argv)
    except UnsupportedCommand as error:
        print(f"action=passthrough reason={error}")
        return
    fields = ["action=" + plan["action"], "input=" + plan["input"],
              "output=" + plan["output"]]
    if plan.get("codec"):
        fields.append("codec=" + plan["codec"])
    if plan.get("bitrate"):
        fields.append("bitrate=" + str(plan["bitrate"]))
    print(" ".join(fields))


def main():
    # The FFmpeg front end forwards a raw command line whose first token is
    # usually an option, so it must bypass argparse entirely.
    if len(sys.argv) > 1 and sys.argv[1] == "plan-ffmpeg":
        try:
            plan_ffmpeg(sys.argv[2:])
        except (OSError, ValueError) as error:
            print(f"dawnshell-codec-ffmpeg: {error}", file=sys.stderr)
            return 1
        return 0
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
    decoder_stats_parser = commands.add_parser("validate-decoder-stats")
    decoder_stats_parser.add_argument("input")
    decoder_stats_parser.add_argument("frames", type=positive_int)
    decoder_stats_parser.set_defaults(handler=validate_decoder_stats)
    encoder_stats_parser = commands.add_parser("validate-encoder-stats")
    encoder_stats_parser.add_argument("input")
    encoder_stats_parser.add_argument("frames", type=positive_int)
    encoder_stats_parser.add_argument("frame_rate", type=positive_int)
    encoder_stats_parser.add_argument("target_bitrate", type=positive_int)
    encoder_stats_parser.add_argument("--output")
    encoder_stats_parser.set_defaults(handler=validate_encoder_stats)
    cleanup_parser = commands.add_parser("validate-cleanup")
    cleanup_parser.add_argument("before")
    cleanup_parser.add_argument("after")
    cleanup_parser.add_argument("sessions", type=positive_int)
    cleanup_parser.set_defaults(handler=validate_cleanup)
    health_parser = commands.add_parser("summarize-health")
    health_parser.add_argument("input")
    health_parser.add_argument("output")
    health_parser.add_argument("--max-fd-growth", type=positive_int, default=2)
    health_parser.add_argument(
        "--max-rss-growth-kb", type=positive_int, default=65536
    )
    health_parser.add_argument(
        "--max-heap-growth-bytes", type=positive_int, default=33554432
    )
    health_parser.set_defaults(handler=summarize_health)
    concurrency_parser = commands.add_parser("validate-concurrency-health")
    concurrency_parser.add_argument("input")
    concurrency_parser.add_argument("sessions", type=positive_int)
    concurrency_parser.add_argument("transcoders", type=int)
    concurrency_parser.set_defaults(handler=validate_concurrency_health)
    balanced_parser = commands.add_parser("validate-balanced-health")
    balanced_parser.add_argument("before")
    balanced_parser.add_argument("after")
    balanced_parser.add_argument("minimum_sessions", type=positive_int)
    balanced_parser.set_defaults(handler=validate_balanced_health)
    quality_parser = commands.add_parser("validate-quality")
    quality_parser.add_argument("psnr_log")
    quality_parser.add_argument("ssim_log")
    quality_parser.add_argument("minimum_psnr", type=float)
    quality_parser.add_argument("minimum_ssim", type=float)
    quality_parser.add_argument("--output")
    quality_parser.set_defaults(handler=validate_quality)
    baseline_parser = commands.add_parser("compare-cpu-baseline")
    baseline_parser.add_argument("before_health")
    baseline_parser.add_argument("after_health")
    baseline_parser.add_argument("hardware_time")
    baseline_parser.add_argument("software_time")
    baseline_parser.add_argument("output")
    baseline_parser.add_argument("--minimum-cpu-reduction-percent", type=float)
    baseline_parser.set_defaults(handler=compare_cpu_baseline)
    timing_parser = commands.add_parser("summarize-time-series")
    timing_parser.add_argument("input")
    timing_parser.add_argument("output")
    timing_parser.add_argument("processed_media_seconds", type=positive_int)
    timing_parser.set_defaults(handler=summarize_time_series)
    arguments = parser.parse_args()
    try:
        arguments.handler(arguments)
    except (OSError, ValueError, decimal.InvalidOperation, ZeroDivisionError) as error:
        print(f"dawnshell-codec-ffmpeg: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
