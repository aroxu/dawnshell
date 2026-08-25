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

usage() {
    echo "usage: dawnshell-codec-long-run MODE [SECONDS]" >&2
    echo "MODE: decode-avc-720, decode-avc-1080, encode-avc-1080, transcode-avc, transcode-hevc, all" >&2
    exit 2
}

[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || usage
mode="$1"
duration="${2:-600}"
case "$duration" in
    ''|*[!0-9]*) usage ;;
esac
if [ "$duration" -lt 10 ] || [ "$duration" -gt 86400 ]; then
    echo "dawnshell-codec-long-run: duration must be within 10..86400 seconds" >&2
    exit 2
fi

if [ "$mode" = all ]; then
    for workload in decode-avc-720 decode-avc-1080 encode-avc-1080 \
        transcode-avc transcode-hevc; do
        "$0" "$workload" "$duration"
    done
    echo "DawnShell codec full long-run suite passed: five workloads x ${duration}s"
    exit 0
fi

vector_dir=/usr/local/share/dawnshell
adapter=/usr/local/libexec/dawnshell-codec-ffmpeg.py
case "$mode" in
    decode-avc-720)
        vector="$vector_dir/avc-baseline-1280x720-30fps-30f.h264"
        expected_hash=7ff494db80cf8a311468f9638384d3d7a7bd320b5b831110076b7c80979af26f
        clip_seconds=1
        ;;
    decode-avc-1080)
        vector="$vector_dir/avc-high-1920x1080-30fps-60f.h264"
        expected_hash=48630f45fa17f58a0435ff0cdb18e42ae466a449cd5d7f7ba966f277b2c8082e
        clip_seconds=2
        ;;
    encode-avc-1080|transcode-avc)
        vector="$vector_dir/avc-high-1920x1080-30fps-60f.h264"
        clip_seconds=2
        ;;
    transcode-hevc)
        vector="$vector_dir/hevc-main-1920x1080-30fps-60f.mp4"
        clip_seconds=2
        ;;
    *) usage ;;
esac

for required in "$vector" "$adapter" /usr/local/bin/dawnshell-codec; do
    [ -f "$required" ] || {
        echo "dawnshell-codec-long-run: missing runtime file: $required" >&2
        exit 3
    }
done

result_root="${DAWNSHELL_CODEC_RESULT_DIR:-/var/log/dawnshell/codec-tests}"
install -d -m 0700 -o root -g root "$result_root"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-${mode}-$$"
result_dir="$result_root/$run_id"
install -d -m 0700 -o root -g root "$result_dir"
temporary="$(mktemp -d /run/dawnshell-codec-long-run.XXXXXX)"
cleanup() {
    case "$temporary" in
        /run/dawnshell-codec-long-run.*) rm -rf -- "$temporary" ;;
    esac
}
terminate() {
    status="$1"
    trap - EXIT HUP INT TERM
    cleanup
    exit "$status"
}
trap cleanup EXIT
trap 'terminate 129' HUP
trap 'terminate 130' INT
trap 'terminate 143' TERM

operations="$result_dir/operations.log"
timings="$result_dir/client-time.tsv"
timing_summary="$result_dir/client-time-summary.json"
output="$temporary/output.bin"
timing_enabled=0
: > "$timings"

run_workload() {
    iteration="$1"
    time_command=()
    if [ "$timing_enabled" -eq 1 ]; then
        time_command=(/usr/bin/time -a
            -f "iteration=$iteration wall_seconds=%e user_seconds=%U system_seconds=%S max_rss_kb=%M"
            -o "$timings")
    fi
    printf '\n=== iteration %s UTC %s ===\n' "$iteration" "$(date -u +%FT%TZ)" \
        >> "$operations"
    case "$mode" in
        decode-avc-720)
            actual="$("${time_command[@]}" timeout 30 dawnshell-codec decode-test \
                "$vector" 1280 720 30 30 2>> "$operations" | sha256sum \
                | awk '{print $1}')"
            ;;
        decode-avc-1080)
            actual="$("${time_command[@]}" timeout 30 dawnshell-codec decode-test \
                "$vector" 1920 1080 30 60 2>> "$operations" | sha256sum \
                | awk '{print $1}')"
            ;;
        encode-avc-1080)
            "${time_command[@]}" timeout 30 dawnshell-codec encode-test \
                1920 1080 30 60 8000000 > "$output" 2>> "$operations"
            actual=unused
            ;;
        transcode-avc)
            "${time_command[@]}" timeout 30 dawnshell-codec transcode-test \
                "$vector" 1920 1080 30 60 8000000 \
                > "$output" 2>> "$operations"
            actual=unused
            ;;
        transcode-hevc)
            "${time_command[@]}" timeout 30 dawnshell-hwtranscode \
                "$vector" "$output.h264" 8000000 >> "$operations" 2>&1
            frames="$(ffprobe -v error -f h264 -count_frames \
                -select_streams v:0 -show_entries stream=nb_read_frames \
                -of default=nokey=1:noprint_wrappers=1 "$output.h264")"
            [ "$frames" = 60 ] || {
                echo "HEVC transcode frame count mismatch: $frames" >> "$operations"
                return 1
            }
            actual=unused
            ;;
    esac
    case "$mode" in
        decode-*)
            [ "$actual" = "$expected_hash" ] || {
                echo "decode checksum mismatch: $actual" >> "$operations"
                return 1
            }
            ;;
    esac
    rm -f "$output" "$output.h264"
}

{
    echo "format=dawnshell-codec-long-run-1"
    echo "test_id=$run_id"
    echo "utc_start=$(date -u +%FT%TZ)"
    echo "mode=$mode"
    echo "requested_duration_seconds=$duration"
    echo "vector=$vector"
    echo "vector_sha256=$(sha256sum "$vector" | awk '{print $1}')"
    echo "kernel=$(uname -a)"
    echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
    echo "load_average_start=$(cat /proc/loadavg)"
    echo "android_build=$(/system/bin/getprop ro.build.fingerprint 2>/dev/null || true)"
    echo "ffmpeg=$(ffmpeg -hide_banner -version | head -n 1)"
} > "$result_dir/environment.tsv"

echo "STAGE: warming hardware codec workload $mode"
run_workload warmup
timing_enabled=1

started="$(date +%s)"
deadline=$((started + duration))
iterations=0
echo "STAGE: running $mode for at least ${duration}s"
while [ "$(date +%s)" -lt "$deadline" ]; do
    iterations=$((iterations + 1))
    if ! run_workload "$iterations"; then
        echo "dawnshell-codec-long-run: workload failed at iteration $iterations" >&2
        echo "Evidence: $result_dir" >&2
        exit 1
    fi
done
finished="$(date +%s)"
elapsed=$((finished - started))
dawnshell-codec health --format json | \
    grep -Fq '"transport":"inherited_memfd_eventfd"'
media_seconds=$((iterations * clip_seconds))
"$adapter" summarize-time-series "$timings" "$timing_summary" "$media_seconds"
realtime_factor="$(mawk -v media="$media_seconds" -v elapsed="$elapsed" \
    'BEGIN { if (elapsed <= 0) exit 1; printf "%.3f", media / elapsed }')"
mawk -v factor="$realtime_factor" 'BEGIN { exit !(factor >= 1.0) }' || {
    echo "dawnshell-codec-long-run: realtime factor $realtime_factor is below 1.0" >&2
    echo "Evidence: $result_dir" >&2
    exit 1
}

{
    echo "utc_end=$(date -u +%FT%TZ)"
    echo "iterations=$iterations"
    echo "elapsed_seconds=$elapsed"
    echo "processed_media_seconds=$media_seconds"
    echo "realtime_factor=$realtime_factor"
    echo "load_average_end=$(cat /proc/loadavg)"
    echo "result=PASS"
} >> "$result_dir/environment.tsv"

echo "DawnShell codec long-run passed: mode=$mode iterations=$iterations elapsed=${elapsed}s realtime=${realtime_factor}x"
echo "Evidence: $result_dir"
