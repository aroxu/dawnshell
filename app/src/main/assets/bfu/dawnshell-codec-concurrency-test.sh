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
temporary="$(mktemp -d /run/dawnshell-codec-concurrency.XXXXXX)"
background_pids=()
cleanup() {
    for pid in "${background_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    case "$temporary" in
        /run/dawnshell-codec-concurrency.*) rm -rf -- "$temporary" ;;
    esac
}
trap cleanup EXIT HUP INT TERM

before="$temporary/health-before.json"
after="$temporary/health-after.json"
dawnshell-codec health --format json > "$before"
passed_pairs=0
skipped_pairs=0

wait_until_ready() {
    pid="$1"
    log="$2"
    for _ in {1..40}; do
        if grep -Fq 'hold-test ready' "$log"; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

run_pair() {
    name="$1"
    first="$2"
    second="$3"
    expected_transcoders="$4"
    first_log="$temporary/${name}-first.log"
    second_log="$temporary/${name}-second.log"
    overlap="$temporary/${name}-overlap.json"

    dawnshell-codec hold-test "$first" 4000 > /dev/null 2> "$first_log" &
    first_pid=$!
    background_pids+=("$first_pid")
    if ! wait_until_ready "$first_pid" "$first_log"; then
        wait "$first_pid" || first_status=$?
        background_pids=()
        first_status="${first_status:-0}"
        cat "$first_log" >&2
        if grep -Fq 'status=-5' "$first_log"; then
            skipped_pairs=$((skipped_pairs + 1))
            echo "SKIP: $name first session reached a hardware resource limit"
            return 0
        fi
        echo "FAIL: $name first session did not become ready (status=$first_status)" >&2
        return 1
    fi

    dawnshell-codec hold-test "$second" 2000 > /dev/null 2> "$second_log" &
    second_pid=$!
    background_pids+=("$second_pid")
    overlap_verified=0
    if wait_until_ready "$second_pid" "$second_log"; then
        dawnshell-codec health --format json > "$overlap"
        "$adapter" validate-concurrency-health "$overlap" 2 \
            "$expected_transcoders"
        overlap_verified=1
    fi

    first_status=0
    second_status=0
    wait "$second_pid" || second_status=$?
    wait "$first_pid" || first_status=$?
    background_pids=()
    if [ "$first_status" -eq 0 ] && [ "$second_status" -eq 0 ] \
        && [ "$overlap_verified" -eq 1 ]; then
        passed_pairs=$((passed_pairs + 1))
        echo "PASS: concurrent pair $name ($first + $second)"
        return 0
    fi
    cat "$first_log" "$second_log" >&2
    if grep -Fq 'status=-5' "$first_log" "$second_log"; then
        skipped_pairs=$((skipped_pairs + 1))
        echo "SKIP: $name reached a bounded hardware resource limit"
        return 0
    fi
    echo "FAIL: $name exited first=$first_status second=$second_status" >&2
    return 1
}

run_pair decoder-plus-encoder decode encode 0
run_pair two-decoders decode decode 0
run_pair transcoder-plus-decoder transcode decode 1

[ "$passed_pairs" -ge 1 ] || {
    echo "FAIL: no concurrent hardware codec pair was accepted" >&2
    exit 1
}
dawnshell-codec health --format json > "$after"
created_sessions="$(grep -hFc 'hold-test ready' "$temporary"/*.log \
    | awk '{sum += $1} END {print sum + 0}')"
[ "$created_sessions" -gt 0 ] || {
    echo "FAIL: concurrency test did not create a session" >&2
    exit 1
}
"$adapter" validate-cleanup "$before" "$after" "$created_sessions"
echo "DawnShell codec concurrency test passed: pairs=$passed_pairs skipped=$skipped_pairs sessions=$created_sessions"
