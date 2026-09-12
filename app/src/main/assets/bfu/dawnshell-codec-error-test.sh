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

adapter=/usr/local/libexec/dawnshell-codec-ffmpeg.pl
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

perl - "$vector" "$temporary" "$temporary/hevc.records" <<'PL_ERROR_VECTORS'
use strict;
use warnings;

# perl-base is Essential in Debian, so this test needs no extra interpreter.

sub slurp {
    my ($path) = @_;
    open(my $handle, "<:raw", $path) or die "cannot read $path: $!\n";
    local $/ = undef;
    my $data = <$handle>;
    close($handle);
    return defined $data ? $data : "";
}

sub spew {
    my ($path, $data) = @_;
    open(my $handle, ">:raw", $path) or die "cannot write $path: $!\n";
    print {$handle} $data;
    close($handle) or die "cannot write $path: $!\n";
}

# The protocol header is a big-endian 64-bit PTS plus two 32-bit fields.
sub record {
    my ($pts, $flags, $size) = @_;
    my $high = int($pts / 4294967296);
    return pack("N4", $high, $pts - $high * 4294967296, $flags, $size);
}

my $source = slurp($ARGV[0]);
my $target = $ARGV[1];
my $hevc_records = $ARGV[2];

# Access-unit delimiters mark the frame boundaries of the public AVC vector.
my @positions;
my $index = 0;
while ($index + 5 < length($source)) {
    my $prefix = 0;
    if (substr($source, $index, 3) eq "\x00\x00\x01") {
        $prefix = 3;
    } elsif (substr($source, $index, 4) eq "\x00\x00\x00\x01") {
        $prefix = 4;
    }
    if ($prefix && (ord(substr($source, $index + $prefix, 1)) & 0x1f) == 9) {
        push @positions, $index;
    }
    $index += $prefix ? $prefix + 1 : 1;
}
die "expected 30 AVC access units, got " . scalar(@positions) . "\n"
    if @positions != 30;
push @positions, length($source);
my @units = map { substr($source, $positions[$_], $positions[$_ + 1] - $positions[$_]) }
    0 .. 29;

sub write_records {
    my ($name, $values) = @_;
    my $payload = "";
    my $frame = 0;
    for my $value (@$values) {
        $payload .= record(int($frame * 1000000 / 30), 0, length($value)) . $value;
        $frame += 1;
    }
    spew("$target/$name", $payload);
}

write_records("missing-config.records", [@units[1 .. 29]]);
my $truncated_length = int(length($units[0]) / 3);
$truncated_length = 8 if $truncated_length < 8;
write_records("truncated-bitstream.records",
    [substr($units[0], 0, $truncated_length)]);

my @damaged = @units;
my $middle = $damaged[10];
my $damage_start = int(length($middle) / 3);
my $damage_end = $damage_start + 32;
$damage_end = length($middle) if $damage_end > length($middle);
for my $offset ($damage_start .. $damage_end - 1) {
    substr($middle, $offset, 1) = chr(ord(substr($middle, $offset, 1)) ^ 0x5a);
}
$damaged[10] = $middle;
write_records("damaged.records", \@damaged);

my $profile = $units[0];
my $profile_mutated = 0;
$index = 0;
while ($index + 8 < length($profile)) {
    my $prefix = 0;
    if (substr($profile, $index, 3) eq "\x00\x00\x01") {
        $prefix = 3;
    } elsif (substr($profile, $index, 4) eq "\x00\x00\x00\x01") {
        $prefix = 4;
    }
    if ($prefix) {
        my $nal = $index + $prefix;
        if ((ord(substr($profile, $nal, 1)) & 0x1f) == 7
                && $nal + 3 < length($profile)) {
            substr($profile, $nal + 1, 1) = chr(244);
            substr($profile, $nal + 3, 1) = chr(255);
            $profile_mutated = 1;
            last;
        }
        $index += $prefix + 1;
    } else {
        $index += 1;
    }
}
die "could not locate AVC SPS for unsupported-profile vector\n"
    unless $profile_mutated;
write_records("unsupported-profile.records", [$profile, @units[1 .. 29]]);
spew("$target/empty.records", "");
spew("$target/truncated-header.records", "\x00" x 8);
spew("$target/length-mismatch.records", record(0, 0, 100) . "x");

sub read_records {
    my ($path) = @_;
    my $data = slurp($path);
    my @result;
    my $offset = 0;
    while ($offset < length($data)) {
        die "truncated generated HEVC record header\n"
            if length($data) - $offset < 16;
        my ($high, $low, $flags, $size) = unpack("N4", substr($data, $offset, 16));
        $offset += 16;
        die "truncated generated HEVC record payload\n"
            if $size > length($data) - $offset;
        push @result, [$high * 4294967296 + $low, $flags,
            substr($data, $offset, $size)];
        $offset += $size;
    }
    return \@result;
}

sub hevc_nal_units {
    my ($data) = @_;
    my @starts;
    my $cursor = 0;
    while ($cursor + 5 < length($data)) {
        if (substr($data, $cursor, 3) eq "\x00\x00\x01") {
            push @starts, [$cursor, 3];
            $cursor += 3;
        } elsif (substr($data, $cursor, 4) eq "\x00\x00\x00\x01") {
            push @starts, [$cursor, 4];
            $cursor += 4;
        } else {
            $cursor += 1;
        }
    }
    my @result;
    for my $unit (0 .. $#starts) {
        my $start = $starts[$unit]->[0];
        my $prefix = $starts[$unit]->[1];
        my $end = $unit < $#starts ? $starts[$unit + 1]->[0] : length($data);
        next unless $start + $prefix + 1 < $end;
        my $nal_type = (ord(substr($data, $start + $prefix, 1)) >> 1) & 0x3f;
        push @result, [$nal_type, substr($data, $start, $end - $start)];
    }
    return \@result;
}

my $hevc = read_records($hevc_records);
my %removed;
for my $value (@$hevc) {
    my $units = hevc_nal_units($value->[2]);
    my $has_config = 0;
    for my $unit (@$units) {
        $has_config = 1 if $unit->[0] >= 32 && $unit->[0] <= 34;
    }
    next unless $has_config;
    my $stripped = "";
    for my $unit (@$units) {
        if ($unit->[0] >= 32 && $unit->[0] <= 34) {
            $removed{$unit->[0]} = 1;
            next;
        }
        $stripped .= $unit->[1];
    }
    $value->[2] = $stripped;
    last;
}
die "could not remove HEVC VPS/SPS/PPS; removed="
    . join(",", sort { $a <=> $b } keys %removed) . "\n"
    unless $removed{32} && $removed{33} && $removed{34};

my $config_payload = "";
for my $value (@$hevc) {
    $config_payload .= record($value->[0], $value->[1], length($value->[2]))
        . $value->[2];
}
spew("$target/missing-hevc-config.records", $config_payload);

my $first = $hevc->[0];
my $keep = int(length($first->[2]) / 4);
$keep = 8 if $keep < 8;
my $truncated_hevc = substr($first->[2], 0, $keep);
spew("$target/truncated-hevc.records",
    record($first->[0], $first->[1], length($truncated_hevc)) . $truncated_hevc);
PL_ERROR_VECTORS

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

echo "STAGE: protocol, state-machine, duplicate-EOS, and recovery errors" | tee -a "$log"
dawnshell-codec negative-test >> "$log" 2>&1
if [ "${DAWNSHELL_CODEC_TEST_IDLE_TIMEOUT:-1}" = 1 ]; then
    echo "STAGE: idle private worker remains responsive" | tee -a "$log"
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

echo "STAGE: abrupt decoder and Surface-transcoder client cleanup" | tee -a "$log"
dawnshell-codec orphan-test decode >> "$log" 2>&1
dawnshell-codec orphan-test transcode >> "$log" 2>&1
sleep 2
dawnshell-codec health --format json | tee -a "$log" \
    | grep -Fq '"transport":"inherited_memfd_eventfd"'

echo "DawnShell codec worker error isolation test passed"
echo "Evidence: $result_dir"
