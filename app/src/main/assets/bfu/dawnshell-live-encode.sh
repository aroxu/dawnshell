#!/bin/bash
set -euo pipefail

export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
    cat <<'EOF'
usage: dawnshell-live-encode [OPTIONS]

Required:
  --input SOURCE             Input URL, file, lavfi expression, or /dev/videoX
  --size WIDTHxHEIGHT        Hardware encoder dimensions (even, 16..4096)
  --fps FPS                  Integer frame rate (1..240)
  --output PATH              Recording file or HLS .m3u8 playlist

Input:
  --input-format FORMAT      auto (default), v4l2, or lavfi
  --input-pixel-format FMT   V4L2 format such as mjpeg or yuyv422
  --realtime                 Pace regular files at their native rate (-re)
  --duration SECONDS         Stop capture after this duration

Encoding/output:
  --bitrate BPS              AVC bitrate, default 4000000
  --output-mode MODE         file (default) or hls
  --hls-time SECONDS         Segment target, default 2
  --hls-list-size COUNT      Playlist window; 0 keeps every segment, default 6
  --hls-delete-segments      Delete segments that leave the live playlist
  --record PATH              Also save fragmented MP4 while output mode is hls
  --print-plan               Print the five-stage pipeline without executing it

The managed private NDK MediaCodec worker is supported only from the root
execution path. Run the actual pipeline with sudo. Audio is not currently
captured. Ctrl-C closes FFmpeg and finalizes the
recording or playlist.
EOF
}

fail() {
    echo "dawnshell-live-encode: $*" >&2
    exit 2
}

require_value() {
    [ "$#" -ge 2 ] || fail "$1 requires a value"
}

input=
input_format=auto
input_pixel_format=
size=
fps=
bit_rate=4000000
output=
output_mode='file'
hls_time=2
hls_list_size=6
hls_delete_segments=false
record=
realtime=false
duration=
print_plan=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input) require_value "$@"; input="$2"; shift 2 ;;
        --input-format) require_value "$@"; input_format="$2"; shift 2 ;;
        --input-pixel-format) require_value "$@"; input_pixel_format="$2"; shift 2 ;;
        --size) require_value "$@"; size="$2"; shift 2 ;;
        --fps) require_value "$@"; fps="$2"; shift 2 ;;
        --bitrate) require_value "$@"; bit_rate="$2"; shift 2 ;;
        --output) require_value "$@"; output="$2"; shift 2 ;;
        --output-mode) require_value "$@"; output_mode="$2"; shift 2 ;;
        --hls-time) require_value "$@"; hls_time="$2"; shift 2 ;;
        --hls-list-size) require_value "$@"; hls_list_size="$2"; shift 2 ;;
        --record) require_value "$@"; record="$2"; shift 2 ;;
        --duration) require_value "$@"; duration="$2"; shift 2 ;;
        --hls-delete-segments) hls_delete_segments=true; shift ;;
        --realtime) realtime=true; shift ;;
        --print-plan) print_plan=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; [ "$#" -eq 0 ] || fail "positional arguments are not supported" ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ -n "$input" ] || fail "--input is required"
[ -n "$size" ] || fail "--size is required"
[ -n "$fps" ] || fail "--fps is required"
[ -n "$output" ] || fail "--output is required"

if [[ "$size" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    width="${BASH_REMATCH[1]}"
    height="${BASH_REMATCH[2]}"
else
    fail "--size must be WIDTHxHEIGHT"
fi
if (( width < 16 || width > 4096 || height < 16 || height > 4096
        || width % 2 != 0 || height % 2 != 0 )); then
    fail "dimensions must be even and within 16..4096"
fi
if ! [[ "$fps" =~ ^[0-9]+$ ]] || (( fps < 1 || fps > 240 )); then
    fail "--fps must be an integer within 1..240"
fi
if ! [[ "$bit_rate" =~ ^[0-9]+$ ]] \
        || (( bit_rate < 1000 || bit_rate > 100000000 )); then
    fail "--bitrate must be within 1000..100000000"
fi
[[ "$hls_time" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid --hls-time"
[[ "$hls_list_size" =~ ^[0-9]+$ ]] || fail "invalid --hls-list-size"
if [ -n "$duration" ]; then
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid --duration"
fi
case "$input_format" in auto|v4l2|lavfi) ;; *) fail "unsupported input format" ;; esac
case "$output_mode" in file|hls) ;; *) fail "output mode must be file or hls" ;; esac
[ -z "$record" ] || [ "$output_mode" = hls ] || \
    fail "--record is valid only with --output-mode hls"

capture=(/usr/bin/ffmpeg -hide_banner -loglevel warning)
[ "$realtime" = false ] || capture+=(-re)
case "$input_format" in
    v4l2)
        capture+=(-thread_queue_size 512 -f v4l2 -framerate "$fps" -video_size "$size")
        [ -z "$input_pixel_format" ] || capture+=(-input_format "$input_pixel_format")
        capture+=(-i "$input")
        ;;
    lavfi) capture+=(-f lavfi -i "$input") ;;
    auto) capture+=(-i "$input") ;;
esac
[ -z "$duration" ] || capture+=(-t "$duration")
capture+=(-map 0:v:0 -an -vf "scale=${width}:${height}:flags=fast_bilinear,format=yuv420p,fps=${fps}" -f rawvideo pipe:1)

pack=(/usr/local/libexec/dawnshell-codec-ffmpeg.py pack-i420 - "$width" "$height" "$fps/1" -)
encode=(/usr/local/bin/dawnshell-codec pipe encode avc "$width" "$height" "$fps" "$bit_rate")
unpack=(/usr/local/libexec/dawnshell-codec-ffmpeg.py unpack-annexb - - --require-keyframe)
mux=(/usr/bin/ffmpeg -hide_banner -loglevel warning -y -r "$fps" -f h264 -i pipe:0 -map 0:v:0 -an -c:v copy)

if [ "$output_mode" = hls ]; then
    hls_flags=independent_segments
    [ "$hls_delete_segments" = false ] || hls_flags+="+delete_segments"
    if [ -n "$record" ]; then
        if [[ "$output" =~ [\|\[\]:] || "$record" =~ [\|\[\]:] ]]; then
            fail "HLS/record paths cannot contain | [ ] or :"
        fi
        tee_spec="[f=hls:hls_time=${hls_time}:hls_list_size=${hls_list_size}:hls_flags=${hls_flags}]${output}|[f=mp4:movflags=+frag_keyframe+empty_moov+default_base_moof]${record}"
        mux+=(-f tee "$tee_spec")
    else
        mux+=(-f hls -hls_time "$hls_time" -hls_list_size "$hls_list_size" -hls_flags "$hls_flags" "$output")
    fi
else
    case "$output" in
        *.mp4|*.MP4|*.mov|*.MOV)
            mux+=(-movflags +frag_keyframe+empty_moov+default_base_moof "$output") ;;
        *) mux+=("$output") ;;
    esac
fi

print_command() {
    printf '%q ' "$@"
    printf '\n'
}

if [ "$print_plan" = true ]; then
    echo "stage=1 capture_to_i420"
    print_command "${capture[@]}"
    echo "stage=2 frame_i420_records"
    print_command "${pack[@]}"
    echo "stage=3_android_mediacodec_avc_encode"
    print_command "${encode[@]}"
    echo "stage=4_unpack_annex_b"
    print_command "${unpack[@]}"
    echo "stage=5_mux_output"
    print_command "${mux[@]}"
    exit 0
fi

[ "$(id -u)" = 0 ] || fail "UID 0 is required; run with sudo"
for required in /usr/bin/ffmpeg /usr/local/bin/dawnshell-codec \
        /usr/local/libexec/dawnshell-codec-ffmpeg.py; do
    [ -x "$required" ] || fail "missing executable: $required"
done
if [ "$input_format" = v4l2 ]; then
    [ -c "$input" ] || fail "V4L2 input is not a character device: $input"
fi

temporary="$(mktemp -d /run/dawnshell-live-encode.XXXXXX)"
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        for log in capture pack codec unpack mux; do
            [ ! -s "$temporary/$log.log" ] || {
                echo "--- $log ---" >&2
                tail -n 80 "$temporary/$log.log" >&2
            }
        done
    fi
    rm -rf -- "$temporary"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "DawnShell live AVC encode: input=$input size=$size fps=$fps bitrate=$bit_rate mode=$output_mode"
"${capture[@]}" 2> "$temporary/capture.log" \
    | "${pack[@]}" 2> "$temporary/pack.log" \
    | "${encode[@]}" 2> "$temporary/codec.log" \
    | "${unpack[@]}" 2> "$temporary/unpack.log" \
    | "${mux[@]}" 2> "$temporary/mux.log"

cat "$temporary/codec.log" >&2
cat "$temporary/unpack.log" >&2
echo "DawnShell live AVC encode complete: output=$output"
