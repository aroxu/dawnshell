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
    arguments = parser.parse_args()
    try:
        arguments.handler(arguments)
    except (OSError, ValueError, decimal.InvalidOperation, ZeroDivisionError) as error:
        print(f"dawnshell-codec-ffmpeg: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
