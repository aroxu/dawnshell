#!/usr/bin/perl
# Packet framing adapter between FFprobe JSON and dawnshell-codec v1.
#
# This tool uses only perl-base, which Debian marks Essential and therefore
# installs with every rootfs. Provisioning never has to fetch an interpreter,
# so the hardware codec bridge works on a minimal Debian installation.

use strict;
use warnings;

my $MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024;
my $RECORD_SIZE = 16;
my $KEYFRAME_FLAG = 1;
my $CODEC_CONFIG_FLAG = 2;
my $EOS_FLAG = 4;

sub fail {
    my ($message) = @_;
    print STDERR "dawnshell-codec-ffmpeg: $message\n";
    exit 1;
}

# ---------------------------------------------------------------------------
# Minimal JSON reader
#
# FFprobe output and dawnshell-codec session statistics are JSON, but JSON::PP
# lives in perl-modules rather than perl-base. Numbers are returned as their
# original text so exact decimal arithmetic stays possible.
# ---------------------------------------------------------------------------

my $json_text = '';

sub json_skip_space {
    $json_text =~ /\G[ \t\r\n]*/gc;
}

sub json_string {
    my %escapes = ('"' => '"', '\\' => '\\', '/' => '/', 'b' => "\b",
                   'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t");
    my $result = '';
    while (1) {
        if ($json_text =~ /\G([^"\\]+)/gc) {
            $result .= $1;
        } elsif ($json_text =~ /\G"/gc) {
            return $result;
        } elsif ($json_text =~ /\G\\u([0-9a-fA-F]{4})/gc) {
            $result .= chr(hex($1));
        } elsif ($json_text =~ /\G\\(.)/gc) {
            fail('invalid JSON string escape') unless exists $escapes{$1};
            $result .= $escapes{$1};
        } else {
            fail('unterminated JSON string');
        }
    }
}

sub json_value {
    json_skip_space();
    if ($json_text =~ /\G\{/gc) {
        my %object;
        json_skip_space();
        return \%object if $json_text =~ /\G\}/gc;
        while (1) {
            json_skip_space();
            fail('invalid JSON object key') unless $json_text =~ /\G"/gc;
            my $key = json_string();
            json_skip_space();
            fail('missing JSON name separator') unless $json_text =~ /\G:/gc;
            $object{$key} = json_value();
            json_skip_space();
            next if $json_text =~ /\G,/gc;
            return \%object if $json_text =~ /\G\}/gc;
            fail('invalid JSON object');
        }
    }
    if ($json_text =~ /\G\[/gc) {
        my @array;
        json_skip_space();
        return \@array if $json_text =~ /\G\]/gc;
        while (1) {
            push @array, json_value();
            json_skip_space();
            next if $json_text =~ /\G,/gc;
            return \@array if $json_text =~ /\G\]/gc;
            fail('invalid JSON array');
        }
    }
    return json_string() if $json_text =~ /\G"/gc;
    # Numbers keep their source text so "0.041667" stays exact.
    return $1 if $json_text =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/gc;
    return 1 if $json_text =~ /\Gtrue/gc;
    return 0 if $json_text =~ /\Gfalse/gc;
    return undef if $json_text =~ /\Gnull/gc;
    fail('invalid JSON input');
}

sub json_decode {
    my ($text) = @_;
    $json_text = $text;
    pos($json_text) = 0;
    my $value = json_value();
    json_skip_space();
    fail('trailing JSON content') if pos($json_text) != length($json_text);
    return $value;
}

sub json_quote {
    my ($value) = @_;
    my $result = $value;
    $result =~ s/\\/\\\\/g;
    $result =~ s/"/\\"/g;
    $result =~ s/\n/\\n/g;
    $result =~ s/\r/\\r/g;
    $result =~ s/\t/\\t/g;
    return '"' . $result . '"';
}

sub json_integer {
    my ($value) = @_;
    return sprintf('%.0f', $value);
}

sub json_number {
    my ($value) = @_;
    my $result = sprintf('%.12g', $value);
    $result .= '.0' if $result !~ /[.eE]/;
    return $result;
}

# Fields arrive as [name, already-encoded JSON value] pairs and are written in
# sorted order so generated reports stay stable between runs.
sub write_json_object {
    my ($path, $fields) = @_;
    my @sorted = sort { $a->[0] cmp $b->[0] } @$fields;
    my $body = join(",\n", map { '  ' . json_quote($_->[0]) . ': ' . $_->[1] } @sorted);
    open(my $output, '>', $path) or fail("cannot write $path: $!");
    print {$output} "{\n" . $body . "\n}\n";
    close($output) or fail("cannot write $path: $!");
}

# ---------------------------------------------------------------------------
# Record framing helpers
# ---------------------------------------------------------------------------

# The protocol header is a 64-bit PTS plus two 32-bit fields, all big-endian.
# Splitting the PTS into two 32-bit words keeps this correct on Perl builds
# without 64-bit pack support.
sub record_header {
    my ($pts, $flags, $size) = @_;
    my $high = int($pts / 4294967296);
    return pack('N4', $high, $pts - $high * 4294967296, $flags, $size);
}

sub parse_record_header {
    my ($header) = @_;
    my ($high, $low, $flags, $size) = unpack('N4', $header);
    return ($high * 4294967296 + $low, $flags, $size);
}

sub autoflush_handle {
    my ($handle) = @_;
    my $previous = select($handle);
    $| = 1;
    select($previous);
}

sub binary_input {
    my ($path) = @_;
    if ($path eq '-') {
        binmode(STDIN, ':raw') or fail("cannot read standard input: $!");
        return \*STDIN;
    }
    open(my $handle, '<:raw', $path) or fail("cannot read $path: $!");
    return $handle;
}

sub binary_output {
    my ($path) = @_;
    if ($path eq '-') {
        binmode(STDOUT, ':raw') or fail("cannot write standard output: $!");
        # A pipe-backed writer must publish each record promptly; otherwise a
        # low-frame-rate live source stalls behind the userspace buffer.
        autoflush_handle(\*STDOUT);
        return \*STDOUT;
    }
    open(my $handle, '>:raw', $path) or fail("cannot write $path: $!");
    return $handle;
}

sub close_output {
    my ($handle, $path) = @_;
    return if $path eq '-';
    close($handle) or fail("cannot write $path: $!");
}

sub read_block {
    my ($handle, $length) = @_;
    my $buffer = '';
    while (length($buffer) < $length) {
        my $chunk = '';
        my $count = read($handle, $chunk, $length - length($buffer));
        fail("read failed: $!") unless defined $count;
        last if $count == 0;
        $buffer .= $chunk;
    }
    return $buffer;
}

sub report_count {
    my ($label, $count, $output_path) = @_;
    if ($output_path eq '-') {
        print STDERR "$label=$count\n";
    } else {
        print "$count\n";
    }
}

sub read_text_file {
    my ($path) = @_;
    open(my $source, '<', $path) or fail("cannot read $path: $!");
    local $/ = undef;
    my $text = <$source>;
    close($source);
    return defined $text ? $text : '';
}

sub load_packets {
    my ($path) = @_;
    my $value = json_decode(read_text_file($path));
    my $packets = ref($value) eq 'HASH' ? $value->{packets} : undef;
    fail('FFprobe JSON has no packet list') unless ref($packets) eq 'ARRAY';
    return $packets;
}

# Exact microsecond conversion. Floating point turns "0.041667" into
# 41666.99... and loses a microsecond on every frame.
sub seconds_to_micros {
    my ($value) = @_;
    my $text = $value;
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    fail("invalid packet time: $value")
        unless $text =~ /^([+-]?)([0-9]*)(?:\.([0-9]*))?$/;
    my $sign = $1;
    my $whole = $2;
    my $fraction = defined $3 ? $3 : '';
    fail("invalid packet time: $value") if $whole eq '' && $fraction eq '';
    $whole = '0' if $whole eq '';
    $fraction = substr($fraction . '000000', 0, 6);
    my $micros = $whole * 1000000 + $fraction;
    return $sign eq '-' ? -$micros : $micros;
}

sub split_rate {
    my ($value) = @_;
    fail("invalid frame rate: $value")
        unless $value =~ m{^([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?)$};
    my $numerator = $1;
    my $denominator = $2;
    fail("invalid frame rate: $value") if $numerator <= 0 || $denominator <= 0;
    return ($numerator, $denominator);
}

sub packet_pts {
    my ($packet, $index, $frame_rate) = @_;
    my $value = $packet->{pts_time};
    $value = $packet->{dts_time} if !defined $value || $value eq 'N/A';
    return seconds_to_micros($value) if defined $value && $value ne 'N/A';
    my ($numerator, $denominator) = split_rate($frame_rate);
    return int($index * 1000000 * $denominator / $numerator);
}

sub parse_rate {
    my ($value) = @_;
    my ($numerator, $denominator) = split_rate($value);
    my $rate = $numerator / $denominator;
    fail('frame rate must be within 1..240') if $rate < 1 || $rate > 240;
    return $rate;
}

sub positive_int {
    my ($value, $label) = @_;
    fail("$label must be a positive integer")
        unless defined $value && $value =~ /^[0-9]+$/ && $value > 0;
    return 0 + $value;
}

sub parse_number {
    my ($value, $message) = @_;
    fail($message)
        unless defined $value
        && $value =~ /^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;
    return 0 + $value;
}

sub packet_field {
    my ($packet, $key, $index) = @_;
    my $value = $packet->{$key};
    fail("invalid Annex-B packet at index $index")
        unless defined $value && $value =~ /^-?[0-9]+$/;
    return 0 + $value;
}

# ---------------------------------------------------------------------------
# Framing commands
# ---------------------------------------------------------------------------

sub command_pack {
    my ($positional) = @_;
    fail('usage: pack INPUT_PACKETS RAW_PACKETS ANNEX_B FRAME_RATE OUTPUT')
        if @$positional != 5;
    my ($input_packets_path, $raw_packets_path, $annex_b_path, $frame_rate,
        $output_path) = @$positional;
    my $input_packets = load_packets($input_packets_path);
    my $raw_packets = load_packets($raw_packets_path);
    if (!@$input_packets || @$input_packets != @$raw_packets) {
        fail('input and Annex-B packet counts differ: '
            . scalar(@$input_packets) . ' != ' . scalar(@$raw_packets));
    }
    my $raw_size = -s $annex_b_path;
    fail("cannot size $annex_b_path: $!") unless defined $raw_size;
    my @pts_values;
    my $shift;
    for my $index (0 .. $#$input_packets) {
        my $pts = packet_pts($input_packets->[$index], $index, $frame_rate);
        push @pts_values, $pts;
        $shift = $pts if !defined $shift || $pts < $shift;
    }
    my $raw = binary_input($annex_b_path);
    my $output = binary_output($output_path);
    for my $index (0 .. $#$raw_packets) {
        my $packet = $raw_packets->[$index];
        my $position = packet_field($packet, 'pos', $index);
        my $size = packet_field($packet, 'size', $index);
        fail("invalid Annex-B packet at index $index")
            if $position < 0 || $size <= 0 || $size > $MAX_MEDIA_PAYLOAD - $RECORD_SIZE;
        fail("Annex-B packet exceeds file at index $index")
            if $position + $size > $raw_size;
        seek($raw, $position, 0) or fail("cannot seek $annex_b_path: $!");
        my $data = read_block($raw, $size);
        fail("short Annex-B packet at index $index") if length($data) != $size;
        my $pts = $pts_values[$index] - $shift;
        fail('normalized packet PTS became negative') if $pts < 0;
        print {$output} record_header($pts, 0, $size) . $data;
    }
    close($raw);
    close_output($output, $output_path);
    print 'packed_packets=' . scalar(@$raw_packets) . " pts_shift_us=$shift\n";
}

sub command_unpack {
    my ($positional) = @_;
    fail('usage: unpack INPUT OUTPUT WIDTH HEIGHT') if @$positional != 4;
    my ($input_path, $output_path, $width, $height) = @$positional;
    $width = positive_int($width, 'width');
    $height = positive_int($height, 'height');
    my $frame_size = int($width * $height * 3 / 2);
    fail('invalid decoded I420 frame size')
        if $frame_size <= 0 || $frame_size > $MAX_MEDIA_PAYLOAD - $RECORD_SIZE;
    my $frames = 0;
    my $previous_pts = -1;
    my $source = binary_input($input_path);
    my $output = binary_output($output_path);
    while (1) {
        my $header = read_block($source, $RECORD_SIZE);
        last if length($header) == 0;
        fail('truncated decoded record header') if length($header) != $RECORD_SIZE;
        my ($pts, $flags, $size) = parse_record_header($header);
        fail('decoded record exceeds protocol limit')
            if $size > $MAX_MEDIA_PAYLOAD - $RECORD_SIZE;
        my $data = read_block($source, $size);
        fail('truncated decoded record payload') if length($data) != $size;
        if ($size) {
            fail("decoded frame $frames has $size bytes; expected $frame_size")
                if $size != $frame_size;
            fail('decoded PTS is not monotonic') if $pts < $previous_pts;
            $previous_pts = $pts;
            print {$output} $data;
            $frames += 1;
        }
        last if $flags & $EOS_FLAG;
    }
    fail('hardware decoder produced no frames') if $frames == 0;
    close_output($output, $output_path);
    report_count('unpacked_i420_frames', $frames, $output_path);
}

sub command_pack_i420 {
    my ($positional) = @_;
    fail('usage: pack-i420 INPUT WIDTH HEIGHT FRAME_RATE OUTPUT')
        if @$positional != 5;
    my ($input_path, $width, $height, $frame_rate, $output_path) = @$positional;
    $width = positive_int($width, 'width');
    $height = positive_int($height, 'height');
    my $frame_size = int($width * $height * 3 / 2);
    fail('invalid I420 frame size')
        if $frame_size <= 0 || $frame_size > $MAX_MEDIA_PAYLOAD - $RECORD_SIZE;
    parse_rate($frame_rate);
    my ($numerator, $denominator) = split_rate($frame_rate);
    my $frames = 0;
    my $source = binary_input($input_path);
    my $output = binary_output($output_path);
    while (1) {
        my $frame = read_block($source, $frame_size);
        last if length($frame) == 0;
        fail('raw I420 input ends with a partial frame')
            if length($frame) != $frame_size;
        my $pts = int($frames * 1000000 * $denominator / $numerator);
        print {$output} record_header($pts, 0, $frame_size) . $frame;
        $frames += 1;
    }
    fail('raw I420 input has no complete frames') if $frames == 0;
    close_output($output, $output_path);
    report_count('packed_i420_frames', $frames, $output_path);
}

sub command_unpack_annexb {
    my ($arguments) = @_;
    my ($options, $positional) = extract_options($arguments,
        '--require-keyframe' => 'flag');
    fail('usage: unpack-annexb INPUT OUTPUT [--require-keyframe]')
        if @$positional != 2;
    my ($input_path, $output_path) = @$positional;
    my $frames = 0;
    my $previous_pts = -1;
    my $first_frame_is_key = 0;
    my $source = binary_input($input_path);
    my $output = binary_output($output_path);
    while (1) {
        my $header = read_block($source, $RECORD_SIZE);
        last if length($header) == 0;
        fail('truncated encoded record header') if length($header) != $RECORD_SIZE;
        my ($pts, $flags, $size) = parse_record_header($header);
        fail('encoded record exceeds protocol limit')
            if $size > $MAX_MEDIA_PAYLOAD - $RECORD_SIZE;
        my $data = read_block($source, $size);
        fail('truncated encoded record payload') if length($data) != $size;
        if ($size) {
            print {$output} $data;
            if (!($flags & $CODEC_CONFIG_FLAG)) {
                if ($frames == 0) {
                    $first_frame_is_key = ($flags & $KEYFRAME_FLAG) ? 1 : 0;
                }
                fail('encoded PTS is not monotonic') if $pts < $previous_pts;
                $previous_pts = $pts;
                $frames += 1;
            }
        }
        last if $flags & $EOS_FLAG;
    }
    fail('hardware encoder produced no frames') if $frames == 0;
    fail('first hardware-encoded frame is not a keyframe')
        if $options->{'--require-keyframe'} && !$first_frame_is_key;
    close_output($output, $output_path);
    report_count('unpacked_annexb_frames', $frames, $output_path);
}

# ---------------------------------------------------------------------------
# Session statistics validation
# ---------------------------------------------------------------------------

sub load_last_stats {
    my ($path) = @_;
    my $prefix = 'dawnshell-codec: session-stats=';
    my $stats;
    open(my $source, '<', $path) or fail("cannot read $path: $!");
    while (my $line = <$source>) {
        next if index($line, $prefix) != 0;
        $stats = json_decode(substr($line, length($prefix)));
    }
    close($source);
    fail('client log has no session statistics') unless ref($stats) eq 'HASH';
    return $stats;
}

sub stats_integer {
    my ($stats, $key, $fallback) = @_;
    my $value = $stats->{$key};
    return $fallback unless defined $value && $value =~ /^-?[0-9]+$/;
    return 0 + $value;
}

sub stats_text {
    my ($stats, $key) = @_;
    my $value = $stats->{$key};
    return defined $value ? "$value" : 'none';
}

sub require_call_latency {
    my ($stats, $label) = @_;
    for my $direction ('input', 'output') {
        my $samples = stats_integer($stats, $direction . '_call_latency_samples', -1);
        my $average = stats_integer($stats, $direction . '_call_latency_avg_us', -1);
        my $maximum = stats_integer($stats, $direction . '_call_latency_max_us', -1);
        if ($samples <= 0 || $average < 0 || $maximum < 0 || $average > $maximum) {
            fail("$label has invalid $direction call latency metrics: "
                . "samples=$samples average_us=$average max_us=$maximum");
        }
    }
}

sub command_validate_stats {
    my ($arguments) = @_;
    my ($options, $positional) = extract_options($arguments,
        '--max-runtime-ms' => 'value');
    fail('usage: validate-stats INPUT FRAMES [--max-runtime-ms MS]')
        if @$positional != 2;
    my ($input, $frames) = @$positional;
    $frames = positive_int($frames, 'frames');
    my $stats = load_last_stats($input);
    require_call_latency($stats, 'transcoder');
    my @checks = (
        ['kind', 'surface_transcoder', 'text'],
        ['transport', 'surface_zero_copy', 'text'],
        ['input_frames', $frames, 'number'],
        ['output_frames', $frames, 'number'],
        ['surface_frames', $frames, 'number'],
        ['cpu_yuv_frames', 0, 'number'],
        ['errors', 0, 'number'],
        ['dropped_frames', 0, 'number'],
    );
    for my $check (@checks) {
        my ($key, $expected, $kind) = @$check;
        my $actual = $stats->{$key};
        my $matches = 0;
        if (defined $actual) {
            $matches = $kind eq 'text'
                ? $actual eq $expected
                : ($actual =~ /^-?[0-9]+$/ && $actual == $expected);
        }
        fail("session statistic $key=" . stats_text($stats, $key)
            . "; expected $expected") unless $matches;
    }
    if (stats_integer($stats, 'input_eos', 0) < 1
            || stats_integer($stats, 'output_eos', 0) < 1) {
        fail('transcoder statistics do not prove EOS completion');
    }
    if (defined $options->{'--max-runtime-ms'}) {
        my $limit = positive_int($options->{'--max-runtime-ms'}, 'max-runtime-ms');
        my $runtime = stats_integer($stats, 'uptime_ms', -1);
        fail('transcoder runtime ' . $runtime . 'ms exceeds '
            . $limit . 'ms media duration')
            if $runtime < 0 || $runtime > $limit;
    }
    print 'surface_zero_copy=verified '
        . "frames=$frames cpu_yuv_frames=0 "
        . 'runtime_ms=' . stats_text($stats, 'uptime_ms') . ' '
        . 'process_cpu_time_ms=' . stats_text($stats, 'process_cpu_time_ms') . ' '
        . 'session_id=' . stats_text($stats, 'session_id') . "\n";
}

sub command_validate_decoder_stats {
    my ($positional) = @_;
    fail('usage: validate-decoder-stats INPUT FRAMES') if @$positional != 2;
    my ($input, $frames) = @$positional;
    $frames = positive_int($frames, 'frames');
    my $stats = load_last_stats($input);
    require_call_latency($stats, 'decoder');
    fail('session is not a bytebuffer decoder')
        unless stats_text($stats, 'kind') eq 'bytebuffer_decoder';
    for my $key ('input_frames', 'output_frames', 'cpu_yuv_frames') {
        fail("decoder $key=" . stats_text($stats, $key) . "; expected $frames")
            if stats_integer($stats, $key, -1) != $frames;
    }
    if (stats_integer($stats, 'input_eos', 0) < 1
            || stats_integer($stats, 'output_eos', 0) < 1) {
        fail('decoder statistics do not prove EOS completion');
    }
    fail('decoder session recorded codec errors')
        if stats_integer($stats, 'errors', -1) != 0;
    fail('decoder did not use the inherited memfd/eventfd transport')
        unless stats_text($stats, 'media_transport') eq 'inherited_memfd_eventfd';
    print 'hardware_decode_statistics=verified '
        . "frames=$frames "
        . 'transport=' . stats_text($stats, 'media_transport') . ' '
        . 'runtime_ms=' . stats_text($stats, 'uptime_ms') . ' '
        . 'process_cpu_time_ms=' . stats_text($stats, 'process_cpu_time_ms') . "\n";
}

sub command_validate_encoder_stats {
    my ($arguments) = @_;
    my ($options, $positional) = extract_options($arguments, '--output' => 'value');
    fail('usage: validate-encoder-stats INPUT FRAMES FRAME_RATE TARGET_BITRATE '
        . '[--output PATH]') if @$positional != 4;
    my ($input, $frames, $frame_rate, $target_bitrate) = @$positional;
    $frames = positive_int($frames, 'frames');
    $frame_rate = positive_int($frame_rate, 'frame_rate');
    $target_bitrate = positive_int($target_bitrate, 'target_bitrate');
    my $stats = load_last_stats($input);
    require_call_latency($stats, 'encoder');
    fail('session is not a bytebuffer encoder')
        unless stats_text($stats, 'kind') eq 'bytebuffer_encoder';
    for my $key ('input_frames', 'output_frames') {
        fail("encoder $key=" . stats_text($stats, $key) . "; expected $frames")
            if stats_integer($stats, $key, -1) != $frames;
    }
    if (stats_integer($stats, 'input_eos', 0) < 1
            || stats_integer($stats, 'output_eos', 0) < 1) {
        fail('encoder statistics do not prove EOS completion');
    }
    fail('encoder statistics report an error or dropped frame')
        if stats_integer($stats, 'errors', -1) != 0
        || stats_integer($stats, 'dropped_frames', -1) != 0;
    my $output_bytes = stats_integer($stats, 'output_bytes', 0);
    fail('encoder produced no compressed bytes') if $output_bytes <= 0;
    my $actual_bitrate = $output_bytes * 8 * $frame_rate / $frames;
    my $target_ratio = $actual_bitrate / $target_bitrate;
    my $input_average = stats_integer($stats, 'input_call_latency_avg_us', -1);
    my $input_maximum = stats_integer($stats, 'input_call_latency_max_us', -1);
    my $output_average = stats_integer($stats, 'output_call_latency_avg_us', -1);
    my $output_maximum = stats_integer($stats, 'output_call_latency_max_us', -1);
    my $rounded_bitrate = sprintf('%.0f', $actual_bitrate);
    if (defined $options->{'--output'}) {
        write_json_object($options->{'--output'}, [
            ['format', json_quote('dawnshell-codec-encoder-metrics-1')],
            ['frames', json_integer($frames)],
            ['frame_rate', json_integer($frame_rate)],
            ['target_bitrate_bps', json_integer($target_bitrate)],
            ['actual_bitrate_bps', $rounded_bitrate],
            ['target_ratio', json_number($target_ratio)],
            ['output_bytes', json_integer($output_bytes)],
            ['input_call_latency_avg_us', json_integer($input_average)],
            ['input_call_latency_max_us', json_integer($input_maximum)],
            ['output_call_latency_avg_us', json_integer($output_average)],
            ['output_call_latency_max_us', json_integer($output_maximum)],
        ]);
    }
    printf("hardware_encode_statistics=verified frames=%d actual_bitrate_bps=%s "
        . "target_bitrate_bps=%d target_ratio=%.4f input_latency_avg_us=%d "
        . "input_latency_max_us=%d output_latency_avg_us=%d "
        . "output_latency_max_us=%d\n",
        $frames, $rounded_bitrate, $target_bitrate, $target_ratio,
        $input_average, $input_maximum, $output_average, $output_maximum);
}

sub command_validate_quality {
    my ($arguments) = @_;
    my ($options, $positional) = extract_options($arguments, '--output' => 'value');
    fail('usage: validate-quality PSNR_LOG SSIM_LOG MINIMUM_PSNR MINIMUM_SSIM '
        . '[--output PATH]') if @$positional != 4;
    my ($psnr_log, $ssim_log, $minimum_psnr, $minimum_ssim) = @$positional;
    $minimum_psnr = parse_number($minimum_psnr, 'minimum_psnr must be a number');
    $minimum_ssim = parse_number($minimum_ssim, 'minimum_ssim must be a number');
    my $psnr_text = read_text_file($psnr_log);
    my $ssim_text = read_text_file($ssim_log);
    my @psnr_matches = $psnr_text =~ /\baverage:([0-9]+(?:\.[0-9]+)?|inf)\b/g;
    my @ssim_matches = $ssim_text =~ /\bAll:([0-9]+(?:\.[0-9]+)?)\b/g;
    fail('FFmpeg PSNR/SSIM summary was not found')
        if !@psnr_matches || !@ssim_matches;
    my $psnr_value = $psnr_matches[-1];
    my $infinite = $psnr_value eq 'inf' ? 1 : 0;
    my $psnr = $infinite ? 9**9**9 : 0 + $psnr_value;
    my $ssim = 0 + $ssim_matches[-1];
    fail(sprintf('average PSNR %.4f is below %.4f dB', $psnr, $minimum_psnr))
        if $psnr < $minimum_psnr;
    fail(sprintf('SSIM %.6f is below %.6f', $ssim, $minimum_ssim))
        if $ssim < $minimum_ssim;
    if (defined $options->{'--output'}) {
        write_json_object($options->{'--output'}, [
            ['format', json_quote('dawnshell-codec-quality-1')],
            ['average_psnr_db', $infinite ? 'null' : json_number($psnr)],
            ['average_psnr_infinite', $infinite ? 'true' : 'false'],
            ['ssim_all', json_number($ssim)],
            ['minimum_psnr_db', json_number($minimum_psnr)],
            ['minimum_ssim', json_number($minimum_ssim)],
        ]);
    }
    printf("codec_quality=verified average_psnr_db=%.4f ssim_all=%.6f\n",
        $psnr, $ssim);
}

sub load_time_metrics {
    my ($path) = @_;
    my %result;
    open(my $source, '<', $path) or fail("cannot read $path: $!");
    while (my $line = <$source>) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless $line =~ /^([^=]+)=(.*)$/;
        $result{$1} = parse_number($2, "invalid metric in $path: $line");
    }
    close($source);
    for my $key ('wall_seconds', 'user_seconds', 'system_seconds', 'max_rss_kb') {
        fail("time report is missing $key: $path")
            if !exists $result{$key} || $result{$key} < 0;
    }
    return \%result;
}

sub command_compare_cpu_baseline {
    my ($arguments) = @_;
    my ($options, $positional) = extract_options($arguments,
        '--minimum-cpu-reduction-percent' => 'value');
    fail('usage: compare-cpu-baseline HARDWARE_LOG HARDWARE_TIME SOFTWARE_TIME OUTPUT')
        if @$positional != 4;
    my ($hardware_log, $hardware_time_path, $software_time_path, $output_path)
        = @$positional;
    my $session = load_last_stats($hardware_log);
    my $worker_cpu_seconds = stats_integer($session, 'process_cpu_time_ms', -1) / 1000.0;
    fail('hardware session did not report NDK worker CPU time')
        if $worker_cpu_seconds < 0;
    fail('hardware session did not use the private worker transport')
        unless stats_text($session, 'media_transport') eq 'inherited_memfd_eventfd';
    my $hardware = load_time_metrics($hardware_time_path);
    my $software = load_time_metrics($software_time_path);
    # GNU time includes the waited worker child, so adding the worker CPU time
    # again would double-count codec process CPU.
    my $hardware_total_cpu = $hardware->{user_seconds} + $hardware->{system_seconds};
    my $software_total_cpu = $software->{user_seconds} + $software->{system_seconds};
    fail('software baseline reported no CPU time') if $software_total_cpu <= 0;
    my $reduction = ($software_total_cpu - $hardware_total_cpu) * 100.0
        / $software_total_cpu;
    my $threshold = $options->{'--minimum-cpu-reduction-percent'};
    if (defined $threshold) {
        $threshold = parse_number($threshold,
            'minimum-cpu-reduction-percent must be a number');
        fail(sprintf('hardware CPU reduction %.3f%% is below %.3f%%',
            $reduction, $threshold)) if $reduction < $threshold;
    }
    write_json_object($output_path, [
        ['format', json_quote('dawnshell-codec-cpu-baseline-1')],
        ['hardware_wall_seconds', json_number($hardware->{wall_seconds})],
        ['hardware_command_cpu_seconds', json_number($hardware_total_cpu)],
        ['hardware_worker_cpu_seconds', json_number($worker_cpu_seconds)],
        ['hardware_total_cpu_seconds', json_number($hardware_total_cpu)],
        ['hardware_client_max_rss_kb', json_number($hardware->{max_rss_kb})],
        ['software_wall_seconds', json_number($software->{wall_seconds})],
        ['software_total_cpu_seconds', json_number($software_total_cpu)],
        ['software_max_rss_kb', json_number($software->{max_rss_kb})],
        ['cpu_reduction_percent', json_number($reduction)],
        ['threshold_enforced', defined $threshold ? 'true' : 'false'],
    ]);
    printf("codec_cpu_baseline=recorded hardware_total_cpu_seconds=%.3f "
        . "software_total_cpu_seconds=%.3f cpu_reduction_percent=%.3f "
        . "threshold_enforced=%s\n",
        $hardware_total_cpu, $software_total_cpu, $reduction,
        defined $threshold ? 'true' : 'false');
}

sub command_summarize_time_series {
    my ($positional) = @_;
    fail('usage: summarize-time-series INPUT OUTPUT PROCESSED_MEDIA_SECONDS')
        if @$positional != 3;
    my ($input_path, $output_path, $processed_media_seconds) = @$positional;
    $processed_media_seconds = positive_int($processed_media_seconds,
        'processed_media_seconds');
    my @samples;
    my $line_number = 0;
    open(my $source, '<', $input_path) or fail("cannot read $input_path: $!");
    while (my $line = <$source>) {
        $line_number += 1;
        my %fields;
        for my $token (split(' ', $line)) {
            $fields{$1} = $2 if $token =~ /^([^=]+)=(.*)$/;
        }
        my %sample;
        for my $key ('iteration', 'wall_seconds', 'user_seconds',
                'system_seconds', 'max_rss_kb') {
            $sample{$key} = parse_number($fields{$key},
                "invalid GNU time sample at line $line_number");
            fail("negative GNU time metric at line $line_number")
                if $sample{$key} < 0;
        }
        push @samples, \%sample;
    }
    close($source);
    fail('GNU time series has no samples') unless @samples;
    for my $index (0 .. $#samples) {
        fail('GNU time iteration sequence is incomplete')
            if $samples[$index]->{iteration} != $index + 1;
    }
    my $user_total = 0;
    my $system_total = 0;
    my $wall_total = 0;
    my $max_rss = 0;
    for my $sample (@samples) {
        $user_total += $sample->{user_seconds};
        $system_total += $sample->{system_seconds};
        $wall_total += $sample->{wall_seconds};
        $max_rss = $sample->{max_rss_kb} if $sample->{max_rss_kb} > $max_rss;
    }
    my $client_cpu_total = $user_total + $system_total;
    write_json_object($output_path, [
        ['format', json_quote('dawnshell-codec-client-time-summary-1')],
        ['samples', json_integer(scalar @samples)],
        ['processed_media_seconds', json_integer($processed_media_seconds)],
        ['wall_seconds_total', json_number($wall_total)],
        ['user_seconds_total', json_number($user_total)],
        ['system_seconds_total', json_number($system_total)],
        ['client_cpu_seconds_total', json_number($client_cpu_total)],
        ['client_cpu_seconds_per_media_second',
            json_number($client_cpu_total / $processed_media_seconds)],
        ['max_rss_kb', json_number($max_rss)],
    ]);
    printf("codec_client_time=recorded samples=%d wall_seconds=%.3f "
        . "cpu_seconds=%.3f max_rss_kb=%.0f\n",
        scalar(@samples), $wall_total, $client_cpu_total, $max_rss);
}

# ---------------------------------------------------------------------------
# FFmpeg command planning
# ---------------------------------------------------------------------------

my %HARDWARE_ENCODERS = (
    'libx264' => 'avc',
    'h264' => 'avc',
    'h264_mediacodec' => 'avc',
    'libx265' => 'hevc',
    'hevc' => 'hevc',
    'hevc_mediacodec' => 'hevc',
);
# Upstream FFmpeg spells the Android codecs this way. Accepting the exact names
# lets ordinary FFmpeg command lines reach the bridge unchanged.
my %MEDIACODEC_ENCODERS = ('h264_mediacodec' => 1, 'hevc_mediacodec' => 1);
my %MEDIACODEC_DECODERS = ('h264_mediacodec' => 1, 'hevc_mediacodec' => 1);
# Decoders the bridge can honour by ignoring them: FFmpeg would have picked the
# same software decoder for the demuxed elementary stream anyway.
my %SOFTWARE_VIDEO_DECODERS = ('h264' => 1, 'hevc' => 1);
my %VIDEO_CODEC_OPTIONS = ('-c:v' => 1, '-codec:v' => 1, '-vcodec' => 1);
my %AUDIO_CODEC_OPTIONS = ('-c:a' => 1, '-codec:a' => 1, '-acodec' => 1);
my %RAW_VIDEO_SUFFIXES = ('.i420' => 1, '.yuv' => 1);
# Options the bridge reproduces exactly. Anything else falls back to plain
# FFmpeg so a filter, scaler, or muxer flag is never silently dropped.
my %PASSTHROUGH_FLAGS = ('-hide_banner' => 1, '-y' => 1, '-n' => 1, '-an' => 1,
                         '-nostdin' => 1);
my %IGNORED_VALUE_OPTIONS = ('-loglevel' => 1, '-v' => 1, '-threads' => 1,
                             '-stats_period' => 1, '-pix_fmt' => 1, '-f' => 1,
                             '-r' => 1, '-hwaccel_output_format' => 1,
                             '-hwaccel_device' => 1, '-hwaccel_flags' => 1);

sub unsupported {
    my ($reason) = @_;
    die "unsupported:$reason\n";
}

sub parse_bitrate {
    my ($value) = @_;
    my $text = lc($value);
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    my $multiplier = 1;
    if ($text =~ s/k$//) {
        $multiplier = 1000;
    } elsif ($text =~ s/m$//) {
        $multiplier = 1000000;
    }
    unsupported('unsupported_bitrate')
        unless $text =~ /^[0-9]*\.?[0-9]*$/ && $text =~ /[0-9]/;
    my $parsed = int($text * $multiplier);
    unsupported('bitrate_out_of_range') if $parsed < 1000 || $parsed > 100000000;
    return $parsed;
}

# This runs independently of full command parsing so an unsupported option never
# hides the fact that hardware was requested by name.
sub requests_mediacodec {
    my ($argv) = @_;
    return 0 if @$argv < 2;
    for my $index (0 .. $#$argv - 1) {
        my $token = $argv->[$index];
        my $value = $argv->[$index + 1];
        return 1 if $token eq '-hwaccel' && $value eq 'mediacodec';
        return 1 if $VIDEO_CODEC_OPTIONS{$token} && $MEDIACODEC_ENCODERS{$value};
    }
    return 0;
}

sub output_suffix {
    my ($path) = @_;
    my $name = $path;
    $name =~ s{^.*[/\\]}{};
    return '' unless $name =~ /(\.[^.]*)$/;
    return lc($1);
}

sub parse_ffmpeg_command {
    my ($argv) = @_;
    my @inputs;
    my $output;
    my $video_codec;
    my $audio_codec;
    my $bitrate;
    my $hardware_decode = 0;
    my $audio_disabled = 0;
    my $index = 0;
    while ($index < @$argv) {
        my $token = $argv->[$index];
        if (index($token, '-') != 0) {
            unsupported('multiple_outputs') if defined $output;
            $output = $token;
            $index += 1;
            next;
        }
        if ($PASSTHROUGH_FLAGS{$token}) {
            $audio_disabled = 1 if $token eq '-an';
            $index += 1;
            next;
        }
        unsupported('missing_option_value') if $index + 1 >= @$argv;
        my $value = $argv->[$index + 1];
        if ($token eq '-i') {
            push @inputs, $value;
        } elsif ($VIDEO_CODEC_OPTIONS{$token}) {
            # FFmpeg applies an option to the next file on the command line, so
            # -c:v before the first -i selects a decoder, not an encoder.
            if (@inputs) {
                $video_codec = $value;
            } elsif ($MEDIACODEC_DECODERS{$value}) {
                $hardware_decode = 1;
            } elsif (!$SOFTWARE_VIDEO_DECODERS{$value}) {
                unsupported('unsupported_decoder');
            }
        } elsif ($AUDIO_CODEC_OPTIONS{$token}) {
            unsupported('unsupported_audio_decoder') unless @inputs;
            unsupported('unsupported_audio_codec')
                if $value ne 'copy' || $audio_disabled;
            $audio_codec = $value;
        } elsif ($token eq '-hwaccel') {
            if ($value eq 'mediacodec') {
                $hardware_decode = 1;
            } elsif ($value ne 'auto' && $value ne 'none') {
                unsupported('unsupported_hwaccel');
            }
        } elsif ($token eq '-b:v') {
            $bitrate = parse_bitrate($value);
        } elsif ($token eq '-map') {
            unsupported('unsupported_map')
                if $value ne '0:v:0' && $value ne '0:v' && $value ne '0';
        } elsif (!$IGNORED_VALUE_OPTIONS{$token}) {
            unsupported('unsupported_option');
        }
        $index += 2;
    }

    unsupported('requires_single_input') if @inputs != 1;
    unsupported('missing_output') unless defined $output;
    unsupported('conflicting_audio_options')
        if $audio_disabled && defined $audio_codec;
    unsupported('stream_copy') if defined $video_codec && $video_codec eq 'copy';

    if (!defined $video_codec) {
        return {action => 'decode', input => $inputs[0], output => $output}
            if $RAW_VIDEO_SUFFIXES{output_suffix($output)};
        unsupported('no_video_encoder');
    }
    unsupported('unsupported_encoder') unless $HARDWARE_ENCODERS{$video_codec};
    my $codec = $HARDWARE_ENCODERS{$video_codec};
    if ($MEDIACODEC_ENCODERS{$video_codec}
            && !($codec eq 'avc' && $hardware_decode)) {
        # Hardware encode only. Surface zero-copy needs an AVC target plus an
        # explicit hardware decode request, so everything else decodes in FFmpeg
        # and encodes on the Android encoder.
        return {
            action => 'encode',
            input => $inputs[0],
            output => $output,
            codec => $codec,
            bitrate => $bitrate,
            audio => $audio_codec,
        };
    }
    unsupported('audio_copy_requires_bytebuffer_encode') if defined $audio_codec;
    return {
        action => 'transcode',
        input => $inputs[0],
        output => $output,
        codec => $codec,
        bitrate => $bitrate,
    };
}

sub plan_ffmpeg {
    my (@argv) = @_;
    my $explicit = requests_mediacodec(\@argv) ? ' explicit=mediacodec' : '';
    my $plan = eval { parse_ffmpeg_command(\@argv) };
    if (!defined $plan) {
        my $error = $@;
        if ($error =~ /^unsupported:(.*)$/m) {
            print "action=passthrough reason=$1$explicit\n";
            return;
        }
        chomp $error;
        fail($error);
    }
    my @fields = ('action=' . $plan->{action}, 'input=' . $plan->{input},
                  'output=' . $plan->{output});
    push @fields, 'codec=' . $plan->{codec} if $plan->{codec};
    push @fields, 'bitrate=' . $plan->{bitrate} if $plan->{bitrate};
    push @fields, 'audio=' . $plan->{audio} if $plan->{audio};
    push @fields, 'explicit=mediacodec' if $explicit;
    print join(' ', @fields) . "\n";
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

sub extract_options {
    my ($arguments, %specification) = @_;
    my %options;
    my @positional;
    my @pending = @$arguments;
    while (@pending) {
        my $token = shift @pending;
        if (exists $specification{$token}) {
            if ($specification{$token} eq 'flag') {
                $options{$token} = 1;
            } else {
                fail("$token needs a value") unless @pending;
                $options{$token} = shift @pending;
            }
            next;
        }
        fail("unknown option: $token") if index($token, '--') == 0;
        push @positional, $token;
    }
    return (\%options, \@positional);
}

my $command = shift @ARGV;
fail('a command is required') unless defined $command;

# The FFmpeg front end forwards a raw command line whose first token is usually
# an option, so it must bypass option parsing entirely.
if ($command eq 'plan-ffmpeg') {
    plan_ffmpeg(@ARGV);
    exit 0;
}

my %COMMANDS = (
    'pack' => \&command_pack,
    'unpack' => \&command_unpack,
    'pack-i420' => \&command_pack_i420,
    'unpack-annexb' => \&command_unpack_annexb,
    'validate-stats' => \&command_validate_stats,
    'validate-decoder-stats' => \&command_validate_decoder_stats,
    'validate-encoder-stats' => \&command_validate_encoder_stats,
    'validate-quality' => \&command_validate_quality,
    'compare-cpu-baseline' => \&command_compare_cpu_baseline,
    'summarize-time-series' => \&command_summarize_time_series,
);
# Commands that accept named options receive the raw argument list; the rest
# receive positional arguments only.
my %RAW_ARGUMENT_COMMANDS = (
    'unpack-annexb' => 1,
    'validate-stats' => 1,
    'validate-encoder-stats' => 1,
    'validate-quality' => 1,
    'compare-cpu-baseline' => 1,
);

fail("unknown command: $command") unless $COMMANDS{$command};
if ($RAW_ARGUMENT_COMMANDS{$command}) {
    $COMMANDS{$command}->(\@ARGV);
} else {
    my ($options, $positional) = extract_options(\@ARGV);
    $COMMANDS{$command}->($positional);
}
exit 0;

